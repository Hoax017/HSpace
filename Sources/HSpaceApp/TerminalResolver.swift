import AppKit

/// Picks the terminal app from the Settings choice. Used by the icon and column views.
enum TerminalResolver {
    /// "auto" prefers iTerm and falls back to Terminal; any other choice is that bundle id, with no silent substitute.
    static func application(choice: String, lookup: (String) -> URL?) -> URL? {
        choice == "auto"
            ? lookup("com.googlecode.iterm2") ?? lookup("com.apple.Terminal")
            : lookup(choice)
    }

    /// Opens `directory` in the chosen terminal; beeps if that app is not installed.
    @MainActor
    static func open(_ directory: URL) {
        let ws = NSWorkspace.shared
        let app = application(choice: Preferences.terminalChoice) { ws.urlForApplication(withBundleIdentifier: $0) }
        guard let app else { NSSound.beep(); return }
        ws.open([directory], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
