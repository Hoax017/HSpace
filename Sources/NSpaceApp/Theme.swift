import AppKit

/// Appearance theme helpers (app layer): the single read point for accent color and light/dark mode.
/// Reads Preferences (externalized config); nil/invalid values fall back to the system default; settings changes refresh at once through broadcastChanged.
@MainActor
enum Theme {
    /// Candidate accent palette (8 colors, RRGGBB); there is also a "System" entry (accentColorHex = nil) that uses controlAccentColor.
    /// Taken from approximate macOS system accent colors; stable regardless of system language.
    static let accentPalette: [(hex: String, nameKey: String)] = [
        ("FF3B30", "accent.red"),
        ("FF9500", "accent.orange"),
        ("FFCC00", "accent.yellow"),
        ("28CD41", "accent.green"),
        ("007AFF", "accent.blue"),
        ("5E5CE6", "accent.indigo"),
        ("AF52DE", "accent.purple"),
        ("FF2D55", "accent.pink"),
    ]

    /// Current accent color: preference hex -> NSColor; nil or parse failure falls back to the system controlAccentColor.
    static var accent: NSColor {
        guard let hex = Preferences.accentColorHex, let color = NSColor(hex: hex) else {
            return .controlAccentColor
        }
        return color
    }

    /// Applies light/dark mode to NSApp (at launch + on settings changes): nil = system / aqua = light / darkAqua = dark
    static func applyAppearance() {
        switch Preferences.appearanceMode {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    /// Theme change broadcast (called after any appearance item changes on the settings page):
    /// applies light/dark first, posts the notification, then walks all windows so each pane refreshes its tint/dimming, effective immediately.
    static func broadcastChanged() {
        applyAppearance()
        NotificationCenter.default.post(name: .nspaceThemeChanged, object: nil)
        for case let wc as MainWindowController in NSApp.windows.compactMap(\.windowController) {
            wc.grid.refreshTheme()
        }
    }
}

extension Notification.Name {
    /// Appearance change broadcast (accent/light-dark/highlight/dimming): pane tinting and content dimming refresh from this
    static let nspaceThemeChanged = Notification.Name("nspaceThemeChanged")
}

extension NSImage {
    /// Official SF Symbol lookup (§6.1: always the official original; no hand-drawn paths, no emoji text as icons);
    /// falls back to `fallback` when the system lacks the symbol.
    static func officialSymbol(_ name: String, fallback: String? = nil,
                              accessibility: String? = nil) -> NSImage? {
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: accessibility) {
            return img
        }
        if let fallback {
            return NSImage(systemSymbolName: fallback, accessibilityDescription: accessibility)
        }
        return nil
    }
}

extension NSColor {
    /// Builds an sRGB color from 6-digit hex (RRGGBB, optional # prefix); invalid length or radix returns nil
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255,
                  alpha: 1)
    }
}
