import Foundation

/// Turns a stream of contact frames into "N fingers went that way".
///
/// The rules are deliberately strict, because the Magic Mouse surface is small
/// and a hand resting on it produces a lot of noise:
///
///   - the finger count must be exactly the configured one at the moment of firing
///   - the swipe must beat a distance threshold on one axis, and that axis must
///     clearly dominate the other
///   - it must happen inside a time window; a slow drift is a rest, not a swipe
///   - after firing, nothing else fires until the fingers come off
///
/// Not thread-safe by itself: it is driven from the multitouch callback thread
/// and guarded by the engine.
public final class GestureRecognizer {

    public struct Recognition {
        public let direction: Direction
        public let fingers: Int
    }

    private enum Phase {
        case idle
        /// Fingers are down and we're measuring from `origin`.
        case tracking(origin: (x: Float, y: Float), startedAt: Double, fingers: Int)
        /// Already fired; wait for the hand to come off before arming again.
        case spent
    }

    private var config: Config
    private var phase: Phase = .idle

    public init(config: Config) {
        self.config = config
    }

    public func update(config: Config) {
        self.config = config
        phase = .idle
    }

    /// `true` while enough fingers are down to be a candidate gesture — this is
    /// what drives scroll suppression, so it must go high on contact, not on
    /// recognition.
    public private(set) var isEngaged = false

    public func handle(touches: [Touch], timestamp: Double) -> Recognition? {
        let down = touches.filter { $0.state.isDown }
        let count = down.count

        isEngaged = count >= config.fingers

        if count == 0 {
            phase = .idle
            return nil
        }

        // Fewer fingers than we need: not a candidate, but the hand is still on
        // the surface, so don't re-arm a spent gesture yet.
        guard count >= config.fingers else {
            if case .tracking = phase { phase = .idle }
            return nil
        }

        let centroid = centroidOf(down)

        switch phase {
        case .spent:
            return nil

        case .idle:
            phase = .tracking(origin: centroid, startedAt: timestamp, fingers: count)
            return nil

        case .tracking(let origin, let startedAt, let fingers):
            // A changed finger count means the hand rearranged itself. Restart
            // the measurement rather than measuring across the change.
            if fingers != count {
                phase = .tracking(origin: centroid, startedAt: timestamp, fingers: count)
                return nil
            }

            if timestamp - startedAt > config.maxGestureDuration {
                phase = .tracking(origin: centroid, startedAt: timestamp, fingers: count)
                return nil
            }

            guard count == config.fingers else { return nil }

            var dx = centroid.x - origin.x
            var dy = centroid.y - origin.y
            if config.invertX { dx = -dx }
            if config.invertY { dy = -dy }

            guard let direction = direction(dx: dx, dy: dy) else { return nil }

            phase = .spent
            return Recognition(direction: direction, fingers: count)
        }
    }

    private func direction(dx: Float, dy: Float) -> Direction? {
        let ax = abs(dx)
        let ay = abs(dy)

        if ay >= config.swipeThreshold, ay > ax * config.axisDominance {
            return dy > 0 ? .up : .down
        }
        if ax >= config.swipeThreshold, ax > ay * config.axisDominance {
            return dx > 0 ? .right : .left
        }
        return nil
    }

    private func centroidOf(_ touches: [Touch]) -> (x: Float, y: Float) {
        var sx: Float = 0
        var sy: Float = 0
        for touch in touches {
            sx += touch.x
            sy += touch.y
        }
        let n = Float(touches.count)
        return (sx / n, sy / n)
    }
}
