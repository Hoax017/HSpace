import Foundation

/// Localization helper: all UI strings pass through here. The script copies every Resources/*.lproj into the .app and
/// Bundle.main picks the language the user prefers for HSpace (System Settings > General > Language & Region > Applications).
/// en is the development region: a key missing from the chosen language falls back to English rather than showing the key.
enum L10n {
    static func t(_ key: String, _ comment: String = "") -> String {
        lookup(key, in: .main, fallback: english)
    }

    /// Localization with interpolation (%@/%d format strings must come through here: a value passed directly to t() is swallowed as the comment)
    static func f(_ key: String, _ args: any CVarArg...) -> String {
        String(format: lookup(key, in: .main, fallback: english), arguments: args)
    }

    /// The English table, read when the preferred language lacks a key. Nil when the bundle ships no en.lproj (test runs).
    private static let english: Bundle? = Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:))

    /// The string for `key` in `bundle`, else in `fallback`, else the key itself
    static func lookup(_ key: String, in bundle: Bundle, fallback: Bundle?) -> String {
        // A value no table holds: the lookup hands it back only when the key is missing
        let absent = "\u{1}"
        let found = bundle.localizedString(forKey: key, value: absent, table: nil)
        if found != absent { return found }
        return fallback?.localizedString(forKey: key, value: key, table: nil) ?? key
    }
}
