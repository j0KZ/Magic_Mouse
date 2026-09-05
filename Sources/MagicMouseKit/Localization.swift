import Foundation

/// The app's strings, in English and Spanish.
///
/// Looks them up in the running bundle, which is how a normal .app works, and
/// falls back to the key itself when there is no bundle at all — which is the
/// case for `mmg-probe` and for `swift test`, neither of which should have to
/// carry a resources folder just to link against this target.
public enum L {

    /// Which language to render in. `nil` means whatever macOS picked.
    public static var forcedLanguage: String? {
        didSet { cachedBundle = nil }
    }

    private static var cachedBundle: Bundle??

    private static var bundle: Bundle? {
        if let cachedBundle { return cachedBundle }
        let resolved: Bundle?
        if let forcedLanguage,
           let path = Bundle.main.path(forResource: forcedLanguage, ofType: "lproj"),
           let specific = Bundle(path: path) {
            resolved = specific
        } else {
            resolved = Bundle.main
        }
        cachedBundle = resolved
        return resolved
    }

    static func string(_ key: String) -> String {
        guard let bundle else { return key }
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }
}

/// `localized("menu.enabled")` — short enough to use everywhere, which is the
/// point: a localization helper nobody wants to type stops getting used.
public func localized(_ key: String) -> String { L.string(key) }

public func localized(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L.string(key), arguments: arguments)
}

extension Direction {
    public var localizedName: String { localized("direction.\(rawValue)") }
}

extension Action {
    public var localizedName: String { localized("action.\(rawValue)") }
}
