import Foundation

/// Turns a stream of contact frames into "N fingers flicked that way".
///
/// The hard lesson from real recordings on this hardware: resting a hand on the
/// Magic Mouse puts three fingers down more than half the time, and those
/// fingers drift far and coherently as the hand shifts. Distance alone cannot
/// tell a deliberate gesture from that drift — a slow three-finger slide and a
/// hand settling look identical.
///
/// What separates them is **speed**. A deliberate flick covers ground in a
/// fraction of a second; drift takes seconds to move the same distance. So this
/// measures displacement over a short sliding time window — a velocity gate —
/// rather than from a fixed origin. Slow motion never accumulates enough within
/// the window to fire, no matter how far it eventually travels. This is the same
/// mechanism the third-party gesture apps rely on, and the reason they expose a
/// sensitivity slider: on a surface this small the gate has to be tuned by hand.
///
/// Also, measure per finger and take the median: losing one of three contacts
/// moves the centroid ~0.17 in x on its own, which the centroid can't tell from
/// a swipe.
///
/// Not thread-safe by itself: it is driven from the multitouch callback thread
/// and guarded by the engine.
public final class GestureRecognizer {

    public struct Recognition {
        public let direction: Direction
        public let fingers: Int
    }

    /// A short position history per finger, oldest first, so displacement can be
    /// measured across a sliding time window instead of from first contact.
    private struct Track {
        var samples: [(t: Double, x: Float, y: Float)] = []

        mutating func add(_ t: Double, _ x: Float, _ y: Float, window: Double) {
            samples.append((t, x, y))
            // Keep a little more than the window, so there's always a sample on
            // the far side of it to measure against.
            let cutoff = t - window * 1.5
            while samples.count > 2, samples.first!.t < cutoff {
                samples.removeFirst()
            }
        }

        /// Displacement from the oldest sample still inside `window` to the
        /// newest. Zero until the finger has been down for the whole window, so
        /// a fresh contact can't fire on its landing jitter.
        func delta(now: Double, window: Double) -> (Float, Float)? {
            guard let last = samples.last else { return nil }
            guard let old = samples.first(where: { now - $0.t <= window }) else { return nil }
            guard now - old.t >= window * 0.5 else { return nil }
            return (last.x - old.x, last.y - old.y)
        }
    }

    private struct Stroke {
        var startedAt: Double
        var lastDownAt: Double
        var tracks: [Int32: Track] = [:]
        var peakFingers = 0
        var overshot = false
        /// One recognition per stroke. A flick that stays on the surface keeps
        /// satisfying the gate frame after frame, and dragging back without
        /// lifting is itself a clean flick the other way — so a single contact
        /// gets a single gesture. Lifting the fingers starts a new stroke, which
        /// is the motion anyone makes to gesture twice anyway.
        var hasFired = false
    }

    private var config: Config
    private var stroke: Stroke?

    /// The last gesture that fired, kept across strokes because the movement it
    /// has to filter — the hand coming back — happens in a *later* stroke, after
    /// the fingers lifted. Per-stroke state cannot see it.
    private var lastFired: (direction: Direction, at: Double)?

    public init(config: Config) {
        self.config = config
    }

    public func update(config: Config) {
        self.config = config
        stroke = nil
        lastFired = nil
        isEngaged = false
    }

    /// `true` while a candidate gesture is in progress. Drives scroll
    /// suppression, so it goes high on contact and stays high across dropouts.
    public private(set) var isEngaged = false

    public func handle(touches: [Touch], timestamp: Double) -> Recognition? {
        let down = touches.filter { $0.state.isDown }
        let grace = Double(config.dropoutGraceMs) / 1000
        let window = Double(config.swipeWindowMs) / 1000

        // The frame stream stops dead when the hand leaves the mouse — there is
        // no closing frame, and the next one may be minutes later. Expire the
        // stroke here, on whatever frame does eventually arrive, or a stale
        // `peakFingers` of 3 would still be standing when two fingers land to
        // scroll, and that scroll would fire a gesture.
        if let current = stroke, timestamp - current.lastDownAt > grace {
            stroke = nil
            isEngaged = false
        }

        if down.isEmpty {
            // A full lift ends the gesture even inside the grace period: what
            // comes back down may be a different hand shape doing something
            // else entirely. The grace is for a *partial* dropout — the outer
            // fingertip that blinks out at the edge of the shell, where some
            // finger is still down — not for this.
            stroke = nil
            isEngaged = false
            return nil
        }

        var current = stroke ?? Stroke(startedAt: timestamp, lastDownAt: timestamp)
        current.lastDownAt = timestamp

        for touch in down {
            current.tracks[touch.id, default: Track()].add(timestamp, touch.x, touch.y, window: window)
        }
        // Drop fingers gone longer than a dropout, so the next swipe isn't
        // measured against a stale sample.
        current.tracks = current.tracks.filter { track in
            guard let last = track.value.samples.last else { return false }
            return timestamp - last.t <= grace
        }

        current.peakFingers = max(current.peakFingers, down.count)
        if down.count > config.fingers { current.overshot = true }
        isEngaged = current.peakFingers >= config.fingers

        defer { stroke = current }

        if current.hasFired { return nil }

        // Fire on peak count, not the instantaneous one. Near the top and
        // bottom edges of this short surface the outer fingertips reach the
        // shell's curve and blink out, dropping 3→2 for a frame or two. Since
        // the stroke had to reach the full count first (a 2-finger scroll never
        // does), accepting one dropout here extends the usable zone from the
        // middle third to nearly the whole surface without opening the door to
        // lower-finger gestures.
        let minLive = max(1, config.fingers - 1)
        guard !current.overshot,
              current.peakFingers >= config.fingers,
              down.count >= minLive,
              current.tracks.count >= minLive
        else { return nil }

        let deltas = current.tracks.values.compactMap { $0.delta(now: timestamp, window: window) }
        guard deltas.count >= minLive else { return nil }

        var dx = median(deltas.map(\.0))
        var dy = median(deltas.map(\.1))
        if config.invertX { dx = -dx }
        if config.invertY { dy = -dy }

        guard let direction = direction(dx: dx, dy: dy) else { return nil }

        // Swallow the return trip: right after a flick one way, a flick the
        // other way is the hand going back, not a gesture. Only the opposite
        // direction is locked out — flicking the same way twice in a row is
        // something people actually do, at around 450 ms apart.
        if let last = lastFired,
           last.direction == direction.opposite,
           timestamp - last.at < Double(config.returnLockoutMs) / 1000 {
            current.hasFired = true
            return nil
        }

        current.hasFired = true
        lastFired = (direction, timestamp)
        return Recognition(direction: direction, fingers: config.fingers)
    }

    private func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
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
}
