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
    /// Distance the fingers must travel, in normalized surface units (0...1).
    /// The Magic Mouse surface is short, so this is deliberately smaller than a
    /// trackpad equivalent would be.
    public var swipeThreshold: Float = 0.09
    /// How much the dominant axis must beat the other one, so a sloppy diagonal
    /// doesn't fire the wrong direction.
    public var axisDominance: Float = 1.6
    /// A swipe that takes longer than this is a rest, not a gesture.
    public var maxGestureDuration: Double = 1.2
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

    public var bindings: [String: String] = [
        Direction.up.rawValue: Action.missionControl.rawValue,
        Direction.down.rawValue: Action.appExpose.rawValue,
        Direction.left.rawValue: Action.spaceLeft.rawValue,
        Direction.right.rawValue: Action.spaceRight.rawValue,
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
        case enabled, fingers, swipeThreshold, axisDominance, maxGestureDuration
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
        axisDominance = try c.decodeIfPresent(Float.self, forKey: .axisDominance) ?? axisDominance
        maxGestureDuration = try c.decodeIfPresent(Double.self, forKey: .maxGestureDuration) ?? maxGestureDuration
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
        suppressScrollTailMs = max(0, min(2000, suppressScrollTailMs))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(fingers, forKey: .fingers)
        try c.encode(swipeThreshold, forKey: .swipeThreshold)
        try c.encode(axisDominance, forKey: .axisDominance)
        try c.encode(maxGestureDuration, forKey: .maxGestureDuration)
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
