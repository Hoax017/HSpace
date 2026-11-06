import AppKit
import SidebarColors

/// Sidebar colours, app-wide: every window shows the same choices
@MainActor
enum SidebarColorsHost {
    static var store: any SidebarColorStoring = SidebarColorStore(directory: AppDelegate.supportDirectory)

    /// Saves a choice and repaints every window's sidebar. Returns the failure to show, if any.
    static func apply(_ change: () throws -> Void) -> String? {
        do {
            try change()
        } catch {
            return error.localizedDescription
        }
        NotificationCenter.default.post(name: .hspaceThemeChanged, object: nil)
        return nil
    }
}

extension SidebarColor {
    /// System colours only: they follow light and dark
    var nsColor: NSColor {
        switch self {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .mint: .systemMint
        case .teal: .systemTeal
        case .blue: .systemBlue
        case .indigo: .systemIndigo
        case .purple: .systemPurple
        case .pink: .systemPink
        case .brown: .systemBrown
        case .gray: .systemGray
        }
    }

    var title: String { L10n.t("sidebar.color.\(rawValue)") }

    /// Menu swatch, so a colour reads at a glance. The title carries the meaning for VoiceOver.
    var swatch: NSImage? {
        NSImage.officialSymbol("circle.fill", accessibility: title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [nsColor]))
    }
}

extension SidebarPalette {
    var title: String { L10n.t("sidebar.palette.\(rawValue)") }
}

/// The items added to the sidebar's context menu
@MainActor
enum SidebarColorMenu {
    /// Colour submenu of one item. Each entry's representedObject is the colour name, empty for None.
    static func colorItem(current: SidebarColor?, target: AnyObject, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: L10n.t("sidebar.colorMenu"), action: nil, keyEquivalent: "")
        let menu = NSMenu(title: item.title)
        let none = menu.addItem(withTitle: L10n.t("sidebar.color.none"), action: action, keyEquivalent: "")
        none.target = target
        none.representedObject = ""
        none.state = current == nil ? .on : .off
        menu.addItem(.separator())
        for color in SidebarColor.allCases {
            let entry = menu.addItem(withTitle: color.title, action: action, keyEquivalent: "")
            entry.target = target
            entry.representedObject = color.rawValue
            entry.image = color.swatch
            entry.state = color == current ? .on : .off
        }
        item.submenu = menu
        return item
    }

    /// Palette submenu, for the whole sidebar. Each entry's representedObject is the palette name.
    static func paletteItem(current: SidebarPalette, target: AnyObject, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: L10n.t("sidebar.paletteMenu"), action: nil, keyEquivalent: "")
        let menu = NSMenu(title: item.title)
        for palette in SidebarPalette.allCases {
            let entry = menu.addItem(withTitle: palette.title, action: action, keyEquivalent: "")
            entry.target = target
            entry.representedObject = palette.rawValue
            entry.state = palette == current ? .on : .off
        }
        item.submenu = menu
        return item
    }
}
