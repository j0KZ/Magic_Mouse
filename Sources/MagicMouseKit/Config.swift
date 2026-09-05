import Foundation

public enum Direction: String, CaseIterable, Sendable {
    case up, down, left, right
}

public enum Action: String, CaseIterable, Sendable {
    case missionControl
    case appExpose
    case spaceLeft
    case spaceRight
    case showDesktop
    case launchpad
    case none
}

/// A key combination expressed the way a person would write it in the config.
public struct KeyComboSpec: Codable, Sendable {
    public var keyCode: Int
    public var modifiers: [String]

    public init(keyCode: Int, modifiers: [String]) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public struct Config: Sendable {

    public enum DeviceSelection: String, Sendable {
        /// External + portrait sensor. Picks the Magic Mouse and leaves the
        /// built-in trackpad alone, which already does these gestures natively.
        case auto
        /// Every device that isn't the built-in trackpad.
        case external
        /// Every multitouch device, trackpad included. Mostly for debugging.
        case all
    }

    public var enabled = true

    // Recognition
    public var fingers = 3
    /// Distance the fingers must travel WITHIN the velocity window, in
    /// normalized surface units (0...1). Because it is measured over a short
    /// window and not from first contact, this is a speed gate: it rejects a
    /// slow drift that eventually covers the same ground.
    public var swipeThreshold: Float = 0.06
    /// The window over which travel is measured, in milliseconds.
    ///
    /// Short — five frames — and that is the counter-intuitive part, arrived at
    /// by sweeping both knobs against the recordings. A resting hand drifts at a
    /// roughly steady speed, so its displacement keeps growing with the window;
    /// a flick is a burst that saturates once the window outlasts it. Widening
    /// the window therefore helps the drift more than the gesture. At 80 ms the
    /// gap between the two is widest: the user's natural flicks land at
    /// 0.07–0.11 while the worst incidental drift reaches 0.058.
    ///
    /// Measured, not guessed. 220 ms with a threshold of 0.24 recognized 1 of 10
    /// natural flicks; 80 ms at 0.06 recognizes 9, with no new false positive on
    /// any recording. See `Fixtures/flick-natural.jsonl`.
    public var swipeWindowMs = 80
    /// How much the dominant axis must beat the other one, so a sloppy diagonal
    /// doesn't fire the wrong direction.
    public var axisDominance: Float = 1.6
    /// How long a finger may vanish before it counts as lifted. On this sensor
    /// the outer fingers blink out for a frame or two at the edges of the
    /// surface; without this the stroke restarts mid-swipe and never fires.
    public var dropoutGraceMs = 200
    /// Set by `mmg-probe` if the surface reports y growing toward you.
    public var invertY = false
    public var invertX = false

    // Devices
    public var deviceSelection: DeviceSelection = .auto

    // Output
    /// Read the real bindings out of com.apple.symbolichotkeys instead of
    /// assuming Apple's factory shortcuts.
    public var useSystemShortcuts = true

    // Interference
    public var suppressScroll = true
    /// Keep swallowing scroll briefly after the fingers lift, to eat the
    /// momentum tail macOS sends on its own.
    public var suppressScrollTailMs = 250
    public var freezeCursorDuringGesture = false

    /// Left and right ship unbound, and that is a hardware fact rather than a
    /// preference: on a 51.5 mm surface three fingers already span x = 0.17 to
    /// 0.88, so there is nowhere sideways to go. In the recordings a deliberate
    /// lateral flick moved 0.024 — less than the 0.056 of incidental sideways
    /// noise while just using the mouse. No threshold separates those. Binding
    /// them anyway would promise a gesture that can never fire; see
    /// `Fixtures/lateral.jsonl`.
    public var bindings: [String: String] = [
        Direction.up.rawValue: Action.missionControl.rawValue,
        Direction.down.rawValue: Action.appExpose.rawValue,
        Direction.left.rawValue: Action.none.rawValue,
        Direction.right.rawValue: Action.none.rawValue,
    ]

    /// Hard override of the key combo for an action, e.g.
    /// `"missionControl": { "keyCode": 126, "modifiers": ["control"] }`.
    public var overrides: [String: KeyComboSpec] = [:]

    public init() {}

    public func action(for direction: Direction) -> Action {
        guard let raw = bindings[direction.rawValue], let action = Action(rawValue: raw) else {
            return .none
        }
        return action
    }
}

// MARK: - Codable, forgiving

extension Config: Codable {
    private enum CodingKeys: String, CodingKey {
        case enabled, fingers, swipeThreshold, swipeWindowMs, axisDominance, dropoutGraceMs
        case invertY, invertX, deviceSelection, useSystemShortcuts
        case suppressScroll, suppressScrollTailMs, freezeCursorDuringGesture
        case bindings, overrides
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Every key is optional so a half-written config still starts the app.
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        fingers = try c.decodeIfPresent(Int.self, forKey: .fingers) ?? fingers
        swipeThreshold = try c.decodeIfPresent(Float.self, forKey: .swipeThreshold) ?? swipeThreshold
        swipeWindowMs = try c.decodeIfPresent(Int.self, forKey: .swipeWindowMs) ?? swipeWindowMs
        axisDominance = try c.decodeIfPresent(Float.self, forKey: .axisDominance) ?? axisDominance
        dropoutGraceMs = try c.decodeIfPresent(Int.self, forKey: .dropoutGraceMs) ?? dropoutGraceMs
        invertY = try c.decodeIfPresent(Bool.self, forKey: .invertY) ?? invertY
        invertX = try c.decodeIfPresent(Bool.self, forKey: .invertX) ?? invertX
        if let raw = try c.decodeIfPresent(String.self, forKey: .deviceSelection),
           let sel = DeviceSelection(rawValue: raw) {
            deviceSelection = sel
        }
        useSystemShortcuts = try c.decodeIfPresent(Bool.self, forKey: .useSystemShortcuts) ?? useSystemShortcuts
        suppressScroll = try c.decodeIfPresent(Bool.self, forKey: .suppressScroll) ?? suppressScroll
        suppressScrollTailMs = try c.decodeIfPresent(Int.self, forKey: .suppressScrollTailMs) ?? suppressScrollTailMs
        freezeCursorDuringGesture = try c.decodeIfPresent(Bool.self, forKey: .freezeCursorDuringGesture) ?? freezeCursorDuringGesture
        bindings = try c.decodeIfPresent([String: String].self, forKey: .bindings) ?? bindings
        overrides = try c.decodeIfPresent([String: KeyComboSpec].self, forKey: .overrides) ?? overrides

        fingers = max(1, min(5, fingers))
        swipeThreshold = max(0.01, min(0.9, swipeThreshold))
        swipeWindowMs = max(60, min(600, swipeWindowMs))
        suppressScrollTailMs = max(0, min(2000, suppressScrollTailMs))
        dropoutGraceMs = max(0, min(1000, dropoutGraceMs))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(fingers, forKey: .fingers)
        try c.encode(swipeThreshold, forKey: .swipeThreshold)
        try c.encode(swipeWindowMs, forKey: .swipeWindowMs)
        try c.encode(axisDominance, forKey: .axisDominance)
        try c.encode(dropoutGraceMs, forKey: .dropoutGraceMs)
        try c.encode(invertY, forKey: .invertY)
        try c.encode(invertX, forKey: .invertX)
        try c.encode(deviceSelection.rawValue, forKey: .deviceSelection)
        try c.encode(useSystemShortcuts, forKey: .useSystemShortcuts)
        try c.encode(suppressScroll, forKey: .suppressScroll)
        try c.encode(suppressScrollTailMs, forKey: .suppressScrollTailMs)
        try c.encode(freezeCursorDuringGesture, forKey: .freezeCursorDuringGesture)
        try c.encode(bindings, forKey: .bindings)
        try c.encode(overrides, forKey: .overrides)
    }
}

// MARK: - Storage

public enum ConfigStore {

    public static var directory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/magic-mouse-gestures", isDirectory: true)
    }

    public static var url: URL { directory.appendingPathComponent("config.json") }

    /// Loads the config, writing a commented default on first run. A malformed
    /// file is reported and ignored rather than stopping the app.
    public static func load() -> (config: Config, error: String?) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            let fresh = Config()
            try? save(fresh)
            return (fresh, nil)
        }
        do {
            let data = try Data(contentsOf: url)
            return (try JSONDecoder().decode(Config.self, from: data), nil)
        } catch {
            return (Config(), "config.json is not valid — using defaults (\(error.localizedDescription))")
        }
    }

    public static func save(_ config: Config) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: url, options: .atomic)
    }
}
