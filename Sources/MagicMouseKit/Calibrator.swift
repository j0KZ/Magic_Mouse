import Foundation

/// Turns a handful of deliberate swipes into the numbers phase 0 needs: which
/// way each axis grows, and how much travel a comfortable swipe actually has on
/// a surface this small.
///
/// Reading that off the live frame dump by eye works, but it makes the person
/// the instrument. This measures instead, and is honest about how noisy the
/// measurement was.
///
/// Driven from the multitouch callback thread, so every mutable field lives
/// behind the lock.
public final class Calibrator {

    public static let shared = Calibrator()

    public enum Axis: String, Codable, Sendable {
        case vertical, horizontal
    }

    /// One step of the calibration: swipe this way, N times.
    public struct Stage: Sendable {
        public let axis: Axis
        /// Asked of the person, in their words.
        public let instruction: String
        /// The config flag this stage settles.
        public let flag: String
        /// The sign we expect on `axis` if the flag should stay `false`.
        public let expectedSign: Float

        public static let forward = Stage(
            axis: .vertical,
            instruction: "Desliza tres dedos HACIA ADELANTE (lejos de ti)",
            flag: "invertY",
            expectedSign: 1
        )

        public static let rightward = Stage(
            axis: .horizontal,
            instruction: "Desliza tres dedos HACIA LA DERECHA",
            flag: "invertX",
            expectedSign: 1
        )
    }

    /// One deliberate swipe. Displacement is measured per finger and then
    /// averaged, rather than from the centroid: when a finger drops out
    /// mid-stroke — which is exactly what we are here to find out about — the
    /// centroid jumps sideways and the centroid-based delta is a lie.
    public struct Stroke: Codable, Sendable {
        public var dx: Float
        public var dy: Float
        /// Total path travelled per axis. Much larger than |d| means a wobble.
        public var pathX: Float
        public var pathY: Float
        public var duration: Double
        public var maxFingers: Int
        /// Contacts the sensor reported, whatever their state. Larger than
        /// `maxFingers` means the fingers were seen but not counted as down —
        /// a state-filter problem, not a sensing one.
        public var maxContacts: Int
        public var framesDown: Int
        public var framesAtTarget: Int
        /// Times the finger count fell away from the target with the hand still down.
        public var dropouts: Int
        public var fingersMeasured: Int
    }

    public struct AxisReport: Codable, Sendable {
        public var axis: Axis
        public var flag: String
        public var strokes: [Stroke]
        /// Signed mean displacement along the axis, in normalized units.
        public var meanDelta: Float
        public var medianTravel: Float
        public var minTravel: Float
        public var maxTravel: Float
        /// Fraction of strokes whose sign matched the majority. 1.0 = consistent.
        public var signAgreement: Double
        public var invertRecommended: Bool
        /// Median |off-axis| / |on-axis|. Feeds axisDominance.
        public var crossAxisRatio: Float
        public var suggestedThreshold: Float
    }

    public struct Report: Codable, Sendable {
        public var device: String
        public var targetFingers: Int
        public var axes: [AxisReport]
        public var framesSeen: Int
        public var suspiciousFrames: Int
        public var maxFingersSeen: Int
        public var maxContactsSeen: Int
        /// Frames at exactly the target count, over all frames with the hand down.
        public var fingerStability: Double
        public var rejectedStrokes: Int
        public var suggestedThreshold: Float
        public var suggestedAxisDominance: Float
        public var invertY: Bool
        public var invertX: Bool
        public var notes: [String]
    }

    // MARK: - Live state

    private struct FingerTrack {
        var firstX: Float
        var firstY: Float
        var lastX: Float
        var lastY: Float
        var pathX: Float = 0
        var pathY: Float = 0
        var frames: Int = 1
    }

    private struct InFlight {
        var startedAt: Double
        var lastAt: Double
        var tracks: [Int32: FingerTrack] = [:]
        var maxFingers: Int = 0
        var maxContacts: Int = 0
        var framesDown: Int = 0
        var framesAtTarget: Int = 0
        var dropouts: Int = 0
        var wasAtTarget = false
    }

    private let lock = NSLock()

    private var stages: [Stage] = []
    private var stageIndex = 0
    private var collected: [[Stroke]] = []
    private var targetFingers = 3
    private var strokesPerStage = 3
    private var deviceDescription = "?"

    private var inFlight: InFlight?
    private var framesSeen = 0
    private var suspiciousFrames = 0
    private var maxFingersSeen = 0
    private var maxContactsSeen = 0
    private var rejectedStrokes = 0
    private var finished = false

    /// Last time an accepted stroke landed, so the caller can time a stage out.
    public private(set) var lastAcceptedAt = CFAbsoluteTimeGetCurrent()

    // MARK: - Callbacks
    //
    // Fired from the multitouch thread. Printing from there is fine; anything
    // heavier should hop to the main queue itself.

    /// A stroke was measured. `reason` is non-nil when it was thrown away.
    public var onStroke: ((Stage, Stroke, Int, String?) -> Void)?
    /// A stage filled up. The next one, or nil when calibration is done.
    public var onStageChange: ((Stage?) -> Void)?
    public var onFinish: ((Report) -> Void)?

    private init() {}

    // MARK: - Driving

    public func begin(stages: [Stage],
                      targetFingers: Int,
                      strokesPerStage: Int,
                      device: String) {
        lock.lock()
        self.stages = stages
        self.targetFingers = targetFingers
        self.strokesPerStage = strokesPerStage
        self.deviceDescription = device
        self.collected = Array(repeating: [], count: stages.count)
        self.stageIndex = 0
        self.finished = false
        self.lastAcceptedAt = CFAbsoluteTimeGetCurrent()
        let first = stages.first
        lock.unlock()

        onStageChange?(first)
    }

    /// Give up on the current stage and move on with whatever it collected.
    public func timeoutStage() {
        lock.lock()
        guard !finished, stageIndex < stages.count else { lock.unlock(); return }
        inFlight = nil
        lock.unlock()
        advanceStage()
    }

    /// Stop early and report on what we have.
    public func finishNow() {
        lock.lock()
        let alreadyDone = finished
        finished = true
        lock.unlock()
        guard !alreadyDone else { return }
        onFinish?(buildReport())
    }

    // MARK: - Frames

    public func record(touches: [Touch], timestamp: Double) {
        lock.lock()

        guard !finished, stageIndex < stages.count else { lock.unlock(); return }

        framesSeen += 1
        if !touches.allSatisfy({ $0.x > -0.5 && $0.x < 1.5 && $0.y > -0.5 && $0.y < 1.5 }) {
            suspiciousFrames += 1
        }

        let down = touches.filter { $0.state.isDown }
        maxFingersSeen = max(maxFingersSeen, down.count)
        maxContactsSeen = max(maxContactsSeen, touches.count)

        if down.isEmpty {
            guard let stroke = inFlight else { lock.unlock(); return }
            inFlight = nil
            let stage = stages[stageIndex]
            lock.unlock()
            finalize(stroke, stage: stage)
            return
        }

        var current = inFlight ?? InFlight(startedAt: timestamp, lastAt: timestamp)
        current.lastAt = timestamp
        current.framesDown += 1
        current.maxFingers = max(current.maxFingers, down.count)
        current.maxContacts = max(current.maxContacts, touches.count)

        let atTarget = down.count == targetFingers
        if atTarget { current.framesAtTarget += 1 }
        if current.wasAtTarget && !atTarget { current.dropouts += 1 }
        current.wasAtTarget = atTarget

        for touch in down {
            if var track = current.tracks[touch.id] {
                track.pathX += abs(touch.x - track.lastX)
                track.pathY += abs(touch.y - track.lastY)
                track.lastX = touch.x
                track.lastY = touch.y
                track.frames += 1
                current.tracks[touch.id] = track
            } else {
                current.tracks[touch.id] = FingerTrack(
                    firstX: touch.x, firstY: touch.y,
                    lastX: touch.x, lastY: touch.y
                )
            }
        }

        inFlight = current
        lock.unlock()
    }

    // MARK: - Stroke bookkeeping

    /// Fingers with fewer frames than this were passing through — a thumb
    /// brushing the shell on the way in, say — and would only add noise.
    private static let minFramesPerFinger = 4
    /// Below this the "swipe" was a tap or a shuffle, not a gesture.
    private static let minTravel: Float = 0.02

    private func finalize(_ raw: InFlight, stage: Stage) {
        let usable = raw.tracks.values.filter { $0.frames >= Self.minFramesPerFinger }

        guard !usable.isEmpty else {
            note(rejection: "sin dedos que durasen lo suficiente", stage: stage, raw: raw)
            return
        }

        var dx: Float = 0, dy: Float = 0, pathX: Float = 0, pathY: Float = 0
        for track in usable {
            dx += track.lastX - track.firstX
            dy += track.lastY - track.firstY
            pathX += track.pathX
            pathY += track.pathY
        }
        let n = Float(usable.count)
        let stroke = Stroke(
            dx: dx / n, dy: dy / n,
            pathX: pathX / n, pathY: pathY / n,
            duration: raw.lastAt - raw.startedAt,
            maxFingers: raw.maxFingers,
            maxContacts: raw.maxContacts,
            framesDown: raw.framesDown,
            framesAtTarget: raw.framesAtTarget,
            dropouts: raw.dropouts,
            fingersMeasured: usable.count
        )

        let onAxis = stage.axis == .vertical ? abs(stroke.dy) : abs(stroke.dx)

        var reason: String?
        if raw.maxFingers < targetFingers {
            reason = raw.maxContacts > raw.maxFingers
                ? "solo \(raw.maxFingers) dedo(s) apoyado(s), aunque el sensor vio \(raw.maxContacts) contacto(s)"
                : "solo llegó a \(raw.maxFingers) dedo(s)"
        } else if onAxis < Self.minTravel {
            reason = String(format: "recorrido de solo %.3f — ¿fue un toque?", onAxis)
        }

        lock.lock()
        if reason != nil {
            rejectedStrokes += 1
        } else {
            collected[stageIndex].append(stroke)
            lastAcceptedAt = CFAbsoluteTimeGetCurrent()
        }
        let index = collected[stageIndex].count
        let full = collected[stageIndex].count >= strokesPerStage
        lock.unlock()

        onStroke?(stage, stroke, index, reason)

        if reason == nil && full { advanceStage() }
    }

    private func note(rejection: String, stage: Stage, raw: InFlight) {
        lock.lock()
        rejectedStrokes += 1
        lock.unlock()
        let stroke = Stroke(dx: 0, dy: 0, pathX: 0, pathY: 0,
                            duration: raw.lastAt - raw.startedAt,
                            maxFingers: raw.maxFingers,
                            maxContacts: raw.maxContacts,
                            framesDown: raw.framesDown,
                            framesAtTarget: raw.framesAtTarget,
                            dropouts: raw.dropouts,
                            fingersMeasured: 0)
        onStroke?(stage, stroke, 0, rejection)
    }

    private func advanceStage() {
        lock.lock()
        stageIndex += 1
        let done = stageIndex >= stages.count
        let next = done ? nil : stages[stageIndex]
        if done { finished = true }
        lastAcceptedAt = CFAbsoluteTimeGetCurrent()
        lock.unlock()

        onStageChange?(next)
        if done { onFinish?(buildReport()) }
    }

    // MARK: - Report

    private func buildReport() -> Report {
        lock.lock()
        let stages = self.stages
        let collected = self.collected
        let target = targetFingers
        let framesSeen = self.framesSeen
        let suspicious = self.suspiciousFrames
        let maxFingers = self.maxFingersSeen
        let maxContacts = self.maxContactsSeen
        let rejected = self.rejectedStrokes
        let device = self.deviceDescription
        lock.unlock()

        var axes: [AxisReport] = []
        var notes: [String] = []
        var framesDown = 0
        var framesAtTarget = 0

        for (i, stage) in stages.enumerated() {
            let strokes = collected[i]
            for stroke in strokes {
                framesDown += stroke.framesDown
                framesAtTarget += stroke.framesAtTarget
            }
            guard !strokes.isEmpty else {
                notes.append("«\(stage.instruction)» no registró ningún trazo válido.")
                continue
            }

            let deltas = strokes.map { stage.axis == .vertical ? $0.dy : $0.dx }
            let cross  = strokes.map { stage.axis == .vertical ? $0.dx : $0.dy }
            let travel = deltas.map(abs).sorted()

            let mean = deltas.reduce(0, +) / Float(deltas.count)
            let positives = deltas.filter { $0 > 0 }.count
            let agreement = Double(max(positives, deltas.count - positives)) / Double(deltas.count)

            let ratios = zip(cross, deltas).map { abs($1) > 0 ? abs($0) / abs($1) : 1 }.sorted()

            // Leave room below the shortest swipe the person actually made, so
            // the threshold never asks for more travel than they offered.
            let median = Self.median(travel)
            let suggestion = Self.clamp(min(median * 0.6, (travel.first ?? median) * 0.8),
                                        low: 0.03, high: 0.4)

            axes.append(AxisReport(
                axis: stage.axis,
                flag: stage.flag,
                strokes: strokes,
                meanDelta: mean,
                medianTravel: median,
                minTravel: travel.first ?? 0,
                maxTravel: travel.last ?? 0,
                signAgreement: agreement,
                invertRecommended: mean * stage.expectedSign < 0,
                crossAxisRatio: Self.median(ratios),
                suggestedThreshold: suggestion
            ))

            if agreement < 0.99 {
                notes.append("«\(stage.instruction)»: los trazos no coinciden en signo (\(Int(agreement * 100)) %). El eje puede estar leyéndose mal, o un trazo salió al revés.")
            }
        }

        // One threshold serves both axes today, so it has to fit the tighter one.
        let threshold = axes.map(\.suggestedThreshold).min() ?? 0.09
        let worstRatio = axes.map(\.crossAxisRatio).max() ?? 0
        let dominance = worstRatio > 0
            ? Self.clamp(min(1.6, 0.8 / worstRatio), low: 1.1, high: 2.5)
            : 1.6

        let stability = framesDown > 0 ? Double(framesAtTarget) / Double(framesDown) : 0

        if stability < 0.8 && framesDown > 0 {
            notes.append(String(format: "Los %d dedos solo se sostienen el %.0f %% del tiempo con la mano apoyada. Por debajo del 80 %% el gesto va a sentirse caprichoso.", target, stability * 100))
        }
        if maxFingers < target {
            notes.append(maxContacts > maxFingers
                ? "Nunca hubo \(target) dedos apoyados a la vez: el máximo fue \(maxFingers), pero el sensor llegó a ver \(maxContacts) contacto(s). Los dedos están ahí; es el filtro de estado el que no los cuenta."
                : "Nunca hubo \(target) dedos a la vez: el máximo fue \(maxFingers), y el sensor tampoco reportó más contactos. El tercer dedo no llega al sensor.")
        }
        if suspicious > 0 {
            notes.append("\(suspicious) frame(s) con coordenadas fuera de rango: el layout de la struct no encaja del todo. Corre `mmg-probe --raw`.")
        }
        if let vertical = axes.first(where: { $0.axis == .vertical }),
           let horizontal = axes.first(where: { $0.axis == .horizontal }),
           vertical.medianTravel > 0, horizontal.medianTravel > 0 {
            let gap = vertical.medianTravel / horizontal.medianTravel
            if gap > 1.4 || gap < 0.71 {
                notes.append(String(format: "El recorrido cómodo difiere %.1f× entre ejes (v %.3f vs h %.3f). Un único swipeThreshold favorece a uno de los dos; convendría separarlo por eje.", gap, vertical.medianTravel, horizontal.medianTravel))
            }
        }

        return Report(
            device: device,
            targetFingers: target,
            axes: axes,
            framesSeen: framesSeen,
            suspiciousFrames: suspicious,
            maxFingersSeen: maxFingers,
            maxContactsSeen: maxContacts,
            fingerStability: stability,
            rejectedStrokes: rejected,
            suggestedThreshold: threshold,
            suggestedAxisDominance: dominance,
            invertY: axes.first(where: { $0.axis == .vertical })?.invertRecommended ?? false,
            invertX: axes.first(where: { $0.axis == .horizontal })?.invertRecommended ?? false,
            notes: notes
        )
    }

    private static func median(_ sorted: [Float]) -> Float {
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    private static func clamp(_ value: Float, low: Float, high: Float) -> Float {
        min(max(value, low), high)
    }
}
