import Foundation

enum RevealSettingError: Error, Equatable {
    /// The preferences system kept the value, so Reveal still goes to `handler`.
    case notRestored(handler: String)

    var message: String {
        switch self {
        case .notRestored(let handler): L10n.f("reveal.notRestored", handler)
        }
    }
}

/// The global NSFileViewer preference that decides which app answers "Reveal in Finder".
struct RevealSetting {
    let applicationID: CFString

    /// Every app reads this one; tests pass a private application id.
    static var system: RevealSetting { RevealSetting(applicationID: kCFPreferencesAnyApplication) }

    private static var key: CFString { "NSFileViewer" as CFString }

    var handler: String? {
        CFPreferencesSynchronize(applicationID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let value = CFPreferencesCopyValue(Self.key, applicationID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
        return value?.isEmpty == true ? nil : value
    }

    func set(handler: String?) {
        CFPreferencesSetValue(Self.key, handler as CFString?, applicationID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(applicationID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    /// Hands Reveal back to Finder, whichever app holds it, including one that has been deleted.
    /// Removing the key is the system default state. Reads it back, because a preferences write can fail silently.
    func restoreSystemDefault() throws {
        set(handler: nil)
        if let handler { throw RevealSettingError.notRestored(handler: handler) }
    }
}
