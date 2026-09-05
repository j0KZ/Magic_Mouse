import Foundation

/// One finger in one frame, decoded from the framework's contact array.
public struct Touch {
    public let id: Int32
    public let state: State
    /// Position on the surface, 0...1 on both axes.
    public let x: Float
    public let y: Float
    public let vx: Float
    public let vy: Float
    /// Total capacitance. Useful as a proxy for how hard the finger is pressing.
    public let size: Float

    public init(id: Int32, state: State, x: Float, y: Float, vx: Float, vy: Float, size: Float) {
        self.id = id
        self.state = state
        self.x = x
        self.y = y
        self.vx = vx
        self.vy = vy
        self.size = size
    }

    public enum State: Int32 {
        case notTouching = 0
        case starting = 1
        case hovering = 2
        case making = 3
        case touching = 4
        case breaking = 5
        case lingering = 6
        case leaving = 7

        /// The two states that mean "this finger is really on the surface".
        public var isDown: Bool { self == .making || self == .touching }
    }
}

public enum TouchDecoder {

    /// Bytes per contact in the framework's array.
    ///
    /// The struct is opaque and its layout is established empirically, so rather
    /// than mirroring it as a Swift struct — where the compiler makes no C-layout
    /// promise — we read the six fields we need at fixed offsets. `mmg-probe
    /// --raw` dumps these bytes so the offsets can be re-verified against any
    /// macOS build.
    public static let stride = 96

    private enum Offset {
        static let identifier = 16
        static let state = 20
        static let normalizedX = 32
        static let normalizedY = 36
        static let velocityX = 40
        static let velocityY = 44
        static let size = 48
    }

    /// Defensive cap: the count comes from a private callback, and a garbage
    /// value would otherwise walk us straight off the end of the buffer.
    public static let maxTouches = 32

    public static func decode(_ base: UnsafeRawPointer, count rawCount: Int32) -> [Touch] {
        guard rawCount > 0 else { return [] }
        let count = min(Int(rawCount), maxTouches)

        var touches: [Touch] = []
        touches.reserveCapacity(count)

        for i in 0..<count {
            let o = i * stride
            let stateRaw = base.loadUnaligned(fromByteOffset: o + Offset.state, as: Int32.self)
            touches.append(Touch(
                id: base.loadUnaligned(fromByteOffset: o + Offset.identifier, as: Int32.self),
                state: Touch.State(rawValue: stateRaw) ?? .notTouching,
                x: base.loadUnaligned(fromByteOffset: o + Offset.normalizedX, as: Float.self),
                y: base.loadUnaligned(fromByteOffset: o + Offset.normalizedY, as: Float.self),
                vx: base.loadUnaligned(fromByteOffset: o + Offset.velocityX, as: Float.self),
                vy: base.loadUnaligned(fromByteOffset: o + Offset.velocityY, as: Float.self),
                size: base.loadUnaligned(fromByteOffset: o + Offset.size, as: Float.self)
            ))
        }
        return touches
    }

    /// Hex dump of one contact, for validating the offsets above on a new macOS.
    public static func rawBytes(_ base: UnsafeRawPointer, index: Int) -> String {
        var out: [String] = []
        for byte in 0..<stride {
            let value = base.loadUnaligned(fromByteOffset: index * stride + byte, as: UInt8.self)
            out.append(String(format: "%02x", value))
            if byte % 4 == 3 { out.append(" ") }
        }
        return out.joined()
    }
}
