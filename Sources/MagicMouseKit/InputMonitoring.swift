import Foundation
import IOKit.hid

/// macOS gates multitouch frames behind Input Monitoring — TCC's `ListenEvent`.
///
/// The failure mode is what makes this worth a file of its own: without the
/// permission, `MTDeviceStart` still succeeds, the device list still fills in,
/// and the frame callback simply never fires. It looks exactly like broken
/// hardware or a bad decode, so ask the question out loud before listening.
///
/// For a CLI the permission belongs to whoever launched it — Terminal, iTerm —
/// not to the binary. A bundled, signed .app gets its own entry.
public enum InputMonitoring {

    public enum Status: String, Sendable {
        case granted, denied, unknown

        public var described: String {
            switch self {
            case .granted: return "concedido"
            case .denied:  return "denegado"
            case .unknown: return "sin decidir"
            }
        }
    }

    public static var status: Status {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied:  return .denied
        default:                      return .unknown
        }
    }

    /// Raises the system prompt the first time it is asked; after that macOS
    /// remembers the answer and this just reports it.
    @discardableResult
    public static func request() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    /// The process the permission will actually be filed under.
    public static var responsibleProcess: String {
        ProcessInfo.processInfo.environment["TERM_PROGRAM"] ?? "la app que lanzó esto"
    }
}
