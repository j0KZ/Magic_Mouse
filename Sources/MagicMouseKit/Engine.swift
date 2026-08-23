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
    guard let device, let touchData, numTouches > 0 else { return 0 }
    let touches = TouchDecoder.decode(touchData, count: numTouches)
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
            // scroll suppressed forever.
            suppressor.setHandDown(false)
            return
        }

        let recognition = recognizer.handle(touches: touches, timestamp: timestamp)

        if currentConfig.suppressScroll || currentConfig.freezeCursorDuringGesture {
            suppressor.setHandDown(recognizer.isEngaged)
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
