import Foundation
import XCTest
@testable import MagicMouseKit

/// Loading the recordings in `Fixtures/` and running them through the real
/// recognizer.
///
/// The path is derived from `#filePath` on purpose: the same files are replayed
/// by `mmg-probe --replay Fixtures/…`, and one copy that both use is worth more
/// than a tidy resource bundle nobody can point the CLI at.
enum Fixture {

    static let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // MagicMouseKitTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("Fixtures", isDirectory: true)

    static func frames(_ name: String) throws -> [FrameLog.Frame] {
        let path = directory.appendingPathComponent(name).path
        let frames = try FrameLog.read(path: path)
        XCTAssertFalse(frames.isEmpty, "\(name) no tiene ni un frame")
        return frames
    }

    /// Everything the recognizer would have fired over a recording.
    static func replay(_ frames: [FrameLog.Frame],
                       config: Config = Config()) -> [(t: Double, direction: Direction)] {
        let recognizer = GestureRecognizer(config: config)
        var fired: [(t: Double, direction: Direction)] = []
        for frame in frames {
            if let recognition = recognizer.handle(touches: frame.touches, timestamp: frame.t) {
                fired.append((frame.t, recognition.direction))
            }
        }
        return fired
    }
}
