import Foundation
import CoreGraphics

/// Eats the scroll macOS generates on its own while three fingers rest on the
/// Magic Mouse.
///
/// This is the part that decides whether the gesture feels finished or
/// improvised: the system's own recognizer sees two of your three fingers and
/// starts scrolling, and there is no supported way to tell it to stand down for
/// one device. So we intercept the scroll and drop it for as long as the hand is
/// on the surface, plus a short tail to absorb the momentum macOS sends after
/// the fingers lift.
///
/// Suppression is a deadline that every engaged frame pushes forward, never a
/// flag that something else has to remember to lower — see `holdSuppression()`.
///
/// The tap is session-wide — it cannot tell a Magic Mouse scroll from a trackpad
/// one — but it is only armed during the fraction of a second when three fingers
/// are down on the mouse, and you are not scrolling with the trackpad at that
/// moment.
public final class ScrollSuppressor {

    private let lock = NSLock()
    private var suppressUntil: CFAbsoluteTime = 0
    private var freezeCursor = false
    private var tailSeconds: Double = 0.25

    /// Floor for how long one frame holds suppression. Frames arrive about every
    /// 15 ms while the hand is down, so anything above that keeps the hold
    /// continuous even if a few arrive late — and it keeps a configured tail of
    /// 0 from meaning "never suppress anything".
    private static let minimumHold: Double = 0.1

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    public private(set) var isRunning = false

    public init() {}

    // MARK: - Called from the multitouch thread

    /// Hold suppression a little longer. Called on every engaged frame, so it
    /// must stay cheap.
    ///
    /// This pushes a deadline forward instead of latching a flag, and that is not
    /// a detail: the multitouch stream **stops** when the hand leaves the mouse.
    /// There is no closing frame to lower a flag on, so a latched flag would stay
    /// raised and scroll would be dead for the rest of the session.
    public func holdSuppression() {
        lock.lock()
        suppressUntil = CFAbsoluteTimeGetCurrent() + max(tailSeconds, Self.minimumHold)
        lock.unlock()
    }

    /// Let scroll through again right now, without waiting out the tail.
    public func release() {
        lock.lock()
        suppressUntil = 0
        lock.unlock()
    }

    public func apply(config: Config) {
        lock.lock()
        tailSeconds = Double(config.suppressScrollTailMs) / 1000.0
        freezeCursor = config.freezeCursorDuringGesture
        lock.unlock()
    }

    fileprivate func shouldSuppress(isMovement: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isMovement && !freezeCursor { return false }
        return CFAbsoluteTimeGetCurrent() < suppressUntil
    }

    fileprivate func wantsMovementEvents() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return freezeCursor
    }

    // MARK: - Tap lifecycle

    @discardableResult
    public func start(config: Config) -> Bool {
        stop()
        apply(config: config)
        guard config.suppressScroll || config.freezeCursorDuringGesture else { return false }

        var mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        if config.freezeCursorDuringGesture {
            mask |= CGEventMask(1 << CGEventType.mouseMoved.rawValue)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: scrollSuppressorCallback,
            userInfo: selfPtr
        ) else { return false }

        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        return true
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        tap = nil
        isRunning = false
    }

    fileprivate func reEnable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}

private func scrollSuppressorCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let suppressor = Unmanaged<ScrollSuppressor>.fromOpaque(userInfo).takeUnretainedValue()

    // The system disables a tap that takes too long, or on a security event.
    // Silently going deaf is the worst failure mode here, so re-arm.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        suppressor.reEnable()
        return nil
    }

    let isMovement = (type == .mouseMoved)
    if isMovement && !suppressor.wantsMovementEvents() {
        return Unmanaged.passUnretained(event)
    }

    if suppressor.shouldSuppress(isMovement: isMovement) {
        return nil
    }
    return Unmanaged.passUnretained(event)
}
