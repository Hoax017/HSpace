import Foundation

/// Localization helper: all UI strings pass through here; en is the base (the script copies the lproj into the .app, read via Bundle.main)
enum L10n {
    static func t(_ key: String, _ comment: String = "") -> String {
        NSLocalizedString(key, comment: comment)
    }

    /// Localization with interpolation (%@/%d format strings must come through here: a value passed directly to t() is swallowed as the comment)
    static func f(_ key: String, _ args: any CVarArg...) -> String {
        String(format: NSLocalizedString(key, comment: ""), arguments: args)
    }
}
