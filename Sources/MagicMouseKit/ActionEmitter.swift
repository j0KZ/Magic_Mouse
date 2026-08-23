import Foundation
import CoreGraphics

public struct KeyCombo: Equatable {
    public let keyCode: CGKeyCode
    public let flags: CGEventFlags

    public init(keyCode: CGKeyCode, flags: CGEventFlags) {
        self.keyCode = keyCode
        self.flags = flags
    }

    public var described: String {
        var parts: [String] = []
        if flags.contains(.maskControl) { parts.append("ctrl") }
        if flags.contains(.maskAlternate) { parts.append("opt") }
        if flags.contains(.maskShift) { parts.append("shift") }
        if flags.contains(.maskCommand) { parts.append("cmd") }
        if flags.contains(.maskSecondaryFn) { parts.append("fn") }
        parts.append(KeyCodes.name(for: keyCode))
        return parts.joined(separator: "+")
    }
}

public enum KeyCodes {
    public static let leftArrow: CGKeyCode = 123
    public static let rightArrow: CGKeyCode = 124
    public static let downArrow: CGKeyCode = 125
    public static let upArrow: CGKeyCode = 126
    public static let f11: CGKeyCode = 103
    public static let f4: CGKeyCode = 118

    static func name(for code: CGKeyCode) -> String {
        switch code {
        case leftArrow: return "←"
        case rightArrow: return "→"
        case downArrow: return "↓"
        case upArrow: return "↑"
        case f11: return "F11"
        case f4: return "F4"
        default: return "key\(code)"
        }
    }

    static func flags(fromNames names: [String]) -> CGEventFlags {
        var flags = CGEventFlags()
        for name in names {
            switch name.lowercased() {
            case "control", "ctrl": flags.insert(.maskControl)
            case "option", "alt", "alternate": flags.insert(.maskAlternate)
            case "shift": flags.insert(.maskShift)
            case "command", "cmd": flags.insert(.maskCommand)
            case "fn", "function": flags.insert(.maskSecondaryFn)
            default: break
            }
        }
        return flags
    }
}

/// Apple's factory shortcuts, and the `AppleSymbolicHotKeys` IDs that hold the
/// user's actual bindings.
///
/// The IDs are only used to *discover* a remapped shortcut. If an ID is absent,
/// disabled, or turns out to mean something else on a given macOS, we fall back
/// to the factory combo below — which is what the vast majority of Macs have.
/// `mmg-probe --hotkeys` prints what was resolved so this can be checked for
/// real instead of trusted.
public enum SymbolicHotKeys {

    public struct Entry {
        public let symbolicID: Int
        public let fallback: KeyCombo
    }

    public static func entry(for action: Action) -> Entry? {
        switch action {
        case .missionControl:
            return Entry(symbolicID: 32, fallback: KeyCombo(keyCode: KeyCodes.upArrow, flags: .maskControl))
        case .appExpose:
            return Entry(symbolicID: 36, fallback: KeyCombo(keyCode: KeyCodes.downArrow, flags: .maskControl))
        case .spaceLeft:
            return Entry(symbolicID: 79, fallback: KeyCombo(keyCode: KeyCodes.leftArrow, flags: .maskControl))
        case .spaceRight:
            return Entry(symbolicID: 81, fallback: KeyCombo(keyCode: KeyCodes.rightArrow, flags: .maskControl))
        case .showDesktop:
            // No symbolic ID we've verified, so this one is fallback-only until
            // the probe tells us what this Mac actually uses.
            return Entry(symbolicID: 0, fallback: KeyCombo(keyCode: KeyCodes.f11, flags: .maskSecondaryFn))
        case .launchpad:
            return Entry(symbolicID: 0, fallback: KeyCombo(keyCode: KeyCodes.f4, flags: .maskSecondaryFn))
        case .none:
            return nil
        }
    }

    /// Reads the binding the user actually has, out of the symbolic hotkeys
    /// preference domain. Returns nil when the entry is missing or disabled.
    public static func systemCombo(symbolicID: Int) -> KeyCombo? {
        guard let defaults = UserDefaults(suiteName: "com.apple.symbolichotkeys"),
              let all = defaults.dictionary(forKey: "AppleSymbolicHotKeys"),
              let entry = all[String(symbolicID)] as? [String: Any]
        else { return nil }

        if let enabled = entry["enabled"] as? Bool, enabled == false { return nil }
        guard let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Any],
              parameters.count >= 3,
              let keyCode = (parameters[1] as? NSNumber)?.intValue,
              let modifiers = (parameters[2] as? NSNumber)?.uint64Value
        else { return nil }

        // 65535 in the keycode slot means "no key assigned".
        guard keyCode >= 0, keyCode < 65535 else { return nil }

        // Cocoa's modifier bits and CGEventFlags share the same numeric values,
        // so the device-independent range maps straight across.
        let flags = CGEventFlags(rawValue: modifiers & 0x001F_0000)
        return KeyCombo(keyCode: CGKeyCode(keyCode), flags: flags)
    }
}

/// Turns a recognized gesture into the same thing the trackpad would have done,
/// by posting the system's own keyboard shortcut.
///
/// This is the deliberately boring route: no synthetic DockSwipe events, no
/// undocumented CGEvent fields, nothing that macOS 27 changed. The gesture fires
/// the action instantly instead of animating under the finger.
public final class ActionEmitter {

    private var resolved: [Action: KeyCombo] = [:]
    private let source = CGEventSource(stateID: .hidSystemState)

    public private(set) var resolutionLog: [String] = []

    public init() {}

    public func resolve(config: Config) {
        resolved.removeAll()
        resolutionLog.removeAll()

        for action in Action.allCases where action != .none {
            guard let entry = SymbolicHotKeys.entry(for: action) else { continue }

            if let spec = config.overrides[action.rawValue] {
                let combo = KeyCombo(keyCode: CGKeyCode(spec.keyCode),
                                     flags: KeyCodes.flags(fromNames: spec.modifiers))
                resolved[action] = combo
                resolutionLog.append("\(action.rawValue): \(combo.described) (config override)")
                continue
            }

            if config.useSystemShortcuts, entry.symbolicID > 0,
               let combo = SymbolicHotKeys.systemCombo(symbolicID: entry.symbolicID) {
                resolved[action] = combo
                resolutionLog.append("\(action.rawValue): \(combo.described) (system, id \(entry.symbolicID))")
                continue
            }

            resolved[action] = entry.fallback
            resolutionLog.append("\(action.rawValue): \(entry.fallback.described) (default)")
        }
    }

    public func combo(for action: Action) -> KeyCombo? { resolved[action] }

    public func perform(_ action: Action) {
        guard action != .none, let combo = resolved[action] else { return }
        post(combo)
    }

    public func post(_ combo: KeyCombo) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: false)
        else { return }
        down.flags = combo.flags
        up.flags = combo.flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
