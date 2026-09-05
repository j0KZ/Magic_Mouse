import Foundation

/// The C callback the framework hands frames to. It cannot capture context, so
/// it forwards to the shared engine.
private func mtFrameCallback(
    device: MultitouchBridge.DeviceRef?,
    touchData: UnsafeRawPointer?,
    numTouches: Int32,
    timestamp: Double,
    frame: Int32
) -> Int32 {
    guard let device else { return 0 }
    // A frame with no contacts is not noise to be filtered out: it is the only
    // in-band signal that the hand left the mouse. Forward it as an empty array
    // so the recognizer can close the stroke.
    let touches: [Touch]
    if let touchData, numTouches > 0 {
        touches = TouchDecoder.decode(touchData, count: numTouches)
    } else {
        touches = []
    }
    Engine.shared.handleFrame(device: device, touches: touches, timestamp: timestamp)
    return 0
}

public final class Engine {

    public static let shared = Engine()

    public struct StartResult {
        public let deviceCount: Int
        public let suppressorRunning: Bool
        public let warnings: [String]
    }

    private let lock = NSLock()
    private var recognizers: [UnsafeMutableRawPointer: GestureRecognizer] = [:]
    private var attached: [MultitouchBridge.DeviceRef] = []
    private let emitter = ActionEmitter()
    private let suppressor = ScrollSuppressor()

    private var config = Config()

    /// Fired on the main queue whenever a gesture is recognized. The app uses it
    /// for the menu bar; the probe uses it to print.
    public var onGesture: ((Direction, Action) -> Void)?

    public private(set) var isRunning = false

    private init() {}

    public var currentConfig: Config {
        lock.lock()
        defer { lock.unlock() }
        return config
    }

    public var shortcutResolution: [String] { emitter.resolutionLog }

    /// How many devices we are currently listening to. The Magic Mouse drops off
    /// Bluetooth when it sleeps, so the app watches this and re-attaches.
    public var attachedDeviceCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return attached.count
    }

    /// Whether the scroll tap is up. It fails to start without Accessibility, and
    /// the permission usually arrives *after* the first launch — so somebody has
    /// to notice and retry, or the gesture works while the scroll it replaces
    /// keeps firing underneath it.
    public var suppressorIsRunning: Bool { suppressor.isRunning }

    /// How many attached devices the current selection *should* have matched.
    /// The watchdog compares against this rather than the raw device count: on a
    /// laptop the built-in trackpad is always in the list and never selected, so
    /// comparing against every device restarts the engine every five seconds
    /// forever whenever the mouse is away.
    public var selectableDeviceCount: Int {
        lock.lock()
        let selection = config.deviceSelection
        lock.unlock()
        return select(from: MultitouchBridge.devices(), using: selection).count
    }

    // MARK: - Lifecycle

    @discardableResult
    public func start(config newConfig: Config) -> StartResult {
        stop()

        var warnings: [String] = []

        lock.lock()
        config = newConfig
        lock.unlock()

        emitter.resolve(config: newConfig)

        guard MultitouchBridge.isAvailable else {
            warnings.append(MultitouchBridge.loadError ?? "MultitouchSupport unavailable")
            return StartResult(deviceCount: 0, suppressorRunning: false, warnings: warnings)
        }

        let all = MultitouchBridge.devices()
        if all.isEmpty { warnings.append("No multitouch devices found.") }

        var selected = select(from: all, using: newConfig.deviceSelection)
        if selected.isEmpty, newConfig.deviceSelection == .auto {
            selected = all.filter { !$0.isBuiltIn }
            if !selected.isEmpty {
                warnings.append("No portrait-sensor device found; falling back to every external device. Run mmg-probe and check the surface dimensions.")
            }
        }
        if selected.isEmpty {
            warnings.append("No device matched the selection '\(newConfig.deviceSelection.rawValue)'. Is the Magic Mouse connected?")
        }

        for device in selected {
            if MultitouchBridge.start(device.ref, callback: mtFrameCallback) {
                lock.lock()
                attached.append(device.ref)
                recognizers[device.ref] = GestureRecognizer(config: newConfig)
                lock.unlock()
            } else {
                warnings.append("Could not start listening on a device.")
            }
        }

        let suppressorRunning = suppressor.start(config: newConfig)
        if newConfig.suppressScroll && !suppressorRunning {
            warnings.append("Scroll suppression could not start — this usually means Accessibility permission is missing.")
        }

        isRunning = !selected.isEmpty
        return StartResult(deviceCount: selected.count,
                           suppressorRunning: suppressorRunning,
                           warnings: warnings)
    }

    public func stop() {
        lock.lock()
        let devices = attached
        attached.removeAll()
        recognizers.removeAll()
        lock.unlock()

        for device in devices {
            MultitouchBridge.stop(device, callback: mtFrameCallback)
        }
        suppressor.stop()
        isRunning = false
    }

    private func select(from devices: [MultitouchBridge.DeviceInfo],
                        using selection: Config.DeviceSelection) -> [MultitouchBridge.DeviceInfo] {
        switch selection {
        case .all: return devices
        case .external: return devices.filter { !$0.isBuiltIn }
        case .auto: return devices.filter { $0.looksLikeMagicMouse }
        }
    }

    // MARK: - Frames

    fileprivate func handleFrame(device: MultitouchBridge.DeviceRef, touches: [Touch], timestamp: Double) {
        lock.lock()
        let currentConfig = config
        let recognizer = recognizers[device]
        lock.unlock()

        guard currentConfig.enabled, let recognizer else {
            // Disabling with the hand still on the mouse would otherwise leave
            // scroll suppressed for the length of the tail.
            suppressor.release()
            return
        }

        let recognition = recognizer.handle(touches: touches, timestamp: timestamp)

        if currentConfig.suppressScroll || currentConfig.freezeCursorDuringGesture {
            if recognizer.isEngaged { suppressor.holdSuppression() }
        }

        guard let recognition else { return }
        let action = currentConfig.action(for: recognition.direction)
        guard action != .none else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.emitter.perform(action)
            self.onGesture?(recognition.direction, action)
        }
    }
}
