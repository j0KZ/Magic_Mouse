import Foundation

/// PAC-safe binding to Apple's private MultitouchSupport.framework.
///
/// On arm64e — every Apple Silicon Mac, including the M5 Pro — declaring these
/// symbols as plain `extern` and calling them directly trips pointer
/// authentication and dies with a bus error. Every symbol is therefore resolved
/// through `dlopen`/`dlsym` and called via an explicit `@convention(c)` pointer.
public enum MultitouchBridge {

    public typealias DeviceRef = UnsafeMutableRawPointer

    /// `void (*)(MTDeviceRef, MTTouch *, int32_t, double, int32_t)`
    ///
    /// Some builds of the framework declare this as returning `int`. Returning a
    /// value the caller ignores is harmless on arm64, so we use `Int32` for both.
    public typealias FrameCallback =
        @convention(c) (DeviceRef?, UnsafeRawPointer?, Int32, Double, Int32) -> Int32

    private typealias FnCreateList     = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias FnRegister       = @convention(c) (DeviceRef, FrameCallback) -> Void
    private typealias FnUnregister     = @convention(c) (DeviceRef, FrameCallback) -> Void
    private typealias FnStart          = @convention(c) (DeviceRef, Int32) -> Void
    private typealias FnStop           = @convention(c) (DeviceRef) -> Void
    private typealias FnIsBuiltIn      = @convention(c) (DeviceRef) -> Bool
    private typealias FnFamilyID       = @convention(c) (DeviceRef, UnsafeMutablePointer<Int32>) -> Int32
    private typealias FnSurfaceDims    = @convention(c) (DeviceRef, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

    private static let handle: UnsafeMutableRawPointer? = dlopen(frameworkPath, RTLD_LAZY)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: type)
    }

    /// `false` means the framework moved or was renamed — i.e. this macOS broke us.
    public static var isAvailable: Bool { handle != nil }

    public static var loadError: String? {
        guard handle == nil else { return nil }
        if let err = dlerror() { return String(cString: err) }
        return "MultitouchSupport.framework could not be loaded"
    }

    // MARK: - Devices

    /// Describes one multitouch device, with just enough detail to tell a Magic
    /// Mouse from a trackpad without hardcoding family IDs we haven't verified.
    public struct DeviceInfo {
        public let ref: DeviceRef
        public let familyID: Int32?
        public let isBuiltIn: Bool
        /// Sensor surface in hundredths of a millimetre, as the framework reports it.
        public let surfaceWidth: Int32?
        public let surfaceHeight: Int32?

        /// The Magic Mouse sensor is taller than it is wide; every trackpad is the
        /// other way round. Combined with "not built in" that identifies the mouse
        /// without guessing at family IDs.
        public var looksLikeMagicMouse: Bool {
            guard !isBuiltIn else { return false }
            guard let w = surfaceWidth, let h = surfaceHeight, w > 0, h > 0 else { return false }
            return h > w
        }

        public var describedSize: String {
            guard let w = surfaceWidth, let h = surfaceHeight else { return "unknown" }
            return String(format: "%.1f × %.1f mm", Double(w) / 100.0, Double(h) / 100.0)
        }
    }

    public static func devices() -> [DeviceInfo] {
        guard let createList = symbol("MTDeviceCreateList", as: FnCreateList.self),
              let listPtr = createList() else { return [] }

        let list = Unmanaged<CFArray>.fromOpaque(listPtr).takeRetainedValue()
        let count = CFArrayGetCount(list)

        let isBuiltIn = symbol("MTDeviceIsBuiltIn", as: FnIsBuiltIn.self)
        let familyID = symbol("MTDeviceGetFamilyID", as: FnFamilyID.self)
        let surfaceDims = symbol("MTDeviceGetSensorSurfaceDimensions", as: FnSurfaceDims.self)

        var result: [DeviceInfo] = []
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let ref = DeviceRef(mutating: raw)

            var family: Int32 = 0
            let familyOK = familyID.map { $0(ref, &family) == 0 } ?? false

            var w: Int32 = 0
            var h: Int32 = 0
            let dimsOK = surfaceDims.map { $0(ref, &w, &h) == 0 } ?? false

            result.append(DeviceInfo(
                ref: ref,
                familyID: familyOK ? family : nil,
                isBuiltIn: isBuiltIn?(ref) ?? false,
                surfaceWidth: dimsOK ? w : nil,
                surfaceHeight: dimsOK ? h : nil
            ))
        }
        return result
    }

    // MARK: - Listening

    @discardableResult
    public static func start(_ device: DeviceRef, callback: @escaping FrameCallback) -> Bool {
        guard let register = symbol("MTRegisterContactFrameCallback", as: FnRegister.self),
              let start = symbol("MTDeviceStart", as: FnStart.self) else { return false }
        register(device, callback)
        start(device, 0)
        return true
    }

    public static func stop(_ device: DeviceRef, callback: @escaping FrameCallback) {
        symbol("MTUnregisterContactFrameCallback", as: FnUnregister.self)?(device, callback)
        symbol("MTDeviceStop", as: FnStop.self)?(device)
    }
}
