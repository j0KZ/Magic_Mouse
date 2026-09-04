import Foundation

/// Recording and replaying contact frames.
///
/// Nearly every question in this project — does the count hold, which way does
/// y grow, would this stroke have fired — can only be answered by a hand on the
/// mouse. Capturing frames once and replaying them turns that into a file, so
/// the recognizer can be changed and re-checked against the same real swipes
/// without asking anyone to swipe again.
public enum FrameLog {

    /// One frame, as JSON Lines. Short keys because these files get long: a
    /// minute of swiping is a few thousand frames.
    public struct Frame: Codable, Sendable {
        public var t: Double
        public var c: [Contact]

        public struct Contact: Codable, Sendable {
            public var i: Int32
            public var s: Int32
            public var x: Float
            public var y: Float

            public init(_ touch: Touch) {
                i = touch.id
                s = touch.state.rawValue
                x = touch.x
                y = touch.y
            }

            public var touch: Touch {
                Touch(id: i, state: Touch.State(rawValue: s) ?? .notTouching,
                      x: x, y: y, vx: 0, vy: 0, size: 0)
            }
        }

        public init(timestamp: Double, touches: [Touch]) {
            t = timestamp
            c = touches.map(Contact.init)
        }

        public var touches: [Touch] { c.map(\.touch) }
    }

    public final class Recorder {
        private let handle: FileHandle
        private let encoder = JSONEncoder()
        private let lock = NSLock()
        public private(set) var frameCount = 0

        public init(path: String) throws {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path, contents: nil)
            handle = try FileHandle(forWritingTo: url)
        }

        /// Called from the multitouch thread, so it takes the lock and writes
        /// straight through — a dropped tail on Ctrl-C would lose exactly the
        /// frames someone just went to the trouble of producing.
        public func write(timestamp: Double, touches: [Touch]) {
            guard let data = try? encoder.encode(Frame(timestamp: timestamp, touches: touches))
            else { return }
            lock.lock()
            defer { lock.unlock() }
            handle.write(data)
            handle.write(Data("\n".utf8))
            frameCount += 1
        }

        public func close() {
            lock.lock()
            defer { lock.unlock() }
            try? handle.close()
        }
    }

    public static func read(path: String) throws -> [Frame] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { line in
            try? decoder.decode(Frame.self, from: Data(line.utf8))
        }
    }
}
