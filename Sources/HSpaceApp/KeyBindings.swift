import AppKit

/// Shortcut registry (externalized config: menu shortcuts are not hard-coded, can be changed in UserDefaults and recorded in the settings window).
/// Storage format "kb.<id>" = "<modsRaw>|<key>"; falls back to the registry default.
@MainActor
enum KeyBindings {
    struct Entry {
        let id: String
        let titleKey: String     // Display name in the settings window (L10n key)
        let defaultKey: String
        let defaultMods: NSEvent.ModifierFlags
    }

    /// Common command registry (the settings window renders from this; a new configurable shortcut = one more line)
    static let registry: [Entry] = [
        Entry(id: "newTab", titleKey: "menu.newWorkspace", defaultKey: "t", defaultMods: [.command]),
        Entry(id: "closeTab", titleKey: "menu.closeWorkspace", defaultKey: "w", defaultMods: [.command]),
        // F5 copy / F6 move to the other pane (QSpace muscle memory; moved in M19 from menu hard-coding to the registry, rebindable)
        Entry(id: "copyToOtherPane", titleKey: "menu.copyToOtherPane", defaultKey: "\u{F708}", defaultMods: []),
        Entry(id: "moveToOtherPane", titleKey: "menu.moveToOtherPane", defaultKey: "\u{F709}", defaultMods: []),
        Entry(id: "nextWorkspace", titleKey: "menu.nextWorkspace", defaultKey: "]", defaultMods: [.command, .shift]),
        Entry(id: "prevWorkspace", titleKey: "menu.prevWorkspace", defaultKey: "[", defaultMods: [.command, .shift]),
        // ⌃⇥ / ⌃⇧⇥ workspace cycling (Tab cannot be a menu keyEquivalent, so an event monitor reads the modifiers from this registry,
        // rather than hard-coding them, satisfying §0 "all shortcuts go through the KeyBindings registry")
        Entry(id: "cycleWorkspace", titleKey: "menu.nextWorkspace", defaultKey: "\t", defaultMods: [.control]),
        Entry(id: "cycleWorkspaceBack", titleKey: "menu.prevWorkspace", defaultKey: "\t", defaultMods: [.control, .shift]),
        Entry(id: "newFolder", titleKey: "menu.newFolder", defaultKey: "n", defaultMods: [.command, .shift]),
        Entry(id: "newFile", titleKey: "menu.newFile", defaultKey: "n", defaultMods: [.command, .option]),
        Entry(id: "quickLook", titleKey: "menu.quickLook", defaultKey: " ", defaultMods: []),
        Entry(id: "getInfo", titleKey: "menu.getInfo", defaultKey: "i", defaultMods: [.command]),
        Entry(id: "duplicate", titleKey: "menu.duplicate", defaultKey: "d", defaultMods: [.command]),
        Entry(id: "moveToTrash", titleKey: "menu.moveToTrash", defaultKey: "\u{8}", defaultMods: [.command]),
        Entry(id: "editTags", titleKey: "menu.editTags", defaultKey: "", defaultMods: []),
        Entry(id: "editComment", titleKey: "menu.editComment", defaultKey: "", defaultMods: []),
        Entry(id: "editFolderIcon", titleKey: "menu.editFolderIcon", defaultKey: "", defaultMods: []),
        Entry(id: "copyPath", titleKey: "menu.copyPath", defaultKey: "c", defaultMods: [.command, .shift]),
        Entry(id: "toggleHidden", titleKey: "menu.toggleHidden", defaultKey: ".", defaultMods: [.command, .shift]),
        // Use Groups (M26): no default key (set your own if wanted), configurable through the registry
        Entry(id: "toggleGrouping", titleKey: "menu.toggleGrouping", defaultKey: "", defaultMods: []),
        Entry(id: "refresh", titleKey: "menu.refresh", defaultKey: "r", defaultMods: [.command]),
        Entry(id: "back", titleKey: "menu.back", defaultKey: "[", defaultMods: [.command]),
        Entry(id: "forward", titleKey: "menu.forward", defaultKey: "]", defaultMods: [.command]),
        Entry(id: "goUp", titleKey: "menu.goUp", defaultKey: "\u{F700}", defaultMods: [.command]),
        Entry(id: "goDown", titleKey: "menu.goDown", defaultKey: "\u{F701}", defaultMods: [.command]),
        Entry(id: "goToPath", titleKey: "menu.goToPath", defaultKey: "l", defaultMods: [.command]),
        Entry(id: "goTrash", titleKey: "menu.goTrash", defaultKey: "", defaultMods: []),
        // User-requested defaults: ⌘F current folder, ⇧⌘F global
        Entry(id: "searchHere", titleKey: "menu.searchHere", defaultKey: "f", defaultMods: [.command]),
        Entry(id: "searchGlobal", titleKey: "menu.searchGlobal", defaultKey: "f", defaultMods: [.command, .shift]),
        Entry(id: "toggleSidebar", titleKey: "menu.toggleSidebar", defaultKey: "s", defaultMods: [.command, .option]),
        // View modes (I-13: moved from hard-coded ⌘1/2/3 to the registry; defaults give way to workspace digits -> ⌥⌘1/2/3, rebindable)
        Entry(id: "viewAsIcons", titleKey: "menu.viewAsIcons", defaultKey: "1", defaultMods: [.command, .option]),
        Entry(id: "viewAsList", titleKey: "menu.viewAsList", defaultKey: "2", defaultMods: [.command, .option]),
        Entry(id: "viewAsColumns", titleKey: "menu.viewAsColumns", defaultKey: "3", defaultMods: [.command, .option]),
    ]
    // Direct workspace digits ⌘1..9 (I-13 user request, QSpace muscle memory)
    + (1...9).map { Entry(id: "workspace\($0)", titleKey: "menu.gotoWorkspace\($0)",
                          defaultKey: "\($0)", defaultMods: [.command]) }
    // Pane layouts ⌃⌘1..5 (M19: moved from menu hard-coding to the registry; titleKey reuses each PaneLayout name key)
    + PaneLayout.allCases.enumerated().map { i, layout in
        Entry(id: "layout\(i + 1)", titleKey: layout.titleKey,
              defaultKey: "\(i + 1)", defaultMods: [.control, .command])
    }

    static func entry(_ id: String) -> Entry? {
        registry.first { $0.id == id }
    }

    /// Binding in effect (user override > registry default)
    static func binding(_ id: String) -> (key: String, mods: NSEvent.ModifierFlags) {
        guard let e = entry(id) else { return ("", []) }
        if let raw = UserDefaults.standard.string(forKey: "kb.\(id)") {
            let parts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2, let mods = UInt(parts[0]) {
                return (String(parts[1]), NSEvent.ModifierFlags(rawValue: mods))
            }
        }
        return (e.defaultKey, e.defaultMods)
    }

    static func set(_ id: String, key: String, mods: NSEvent.ModifierFlags) {
        UserDefaults.standard.set("\(mods.rawValue)|\(key)", forKey: "kb.\(id)")
    }

    static func reset(_ id: String) {
        UserDefaults.standard.removeObject(forKey: "kb.\(id)")
    }

    /// Apply to a menu item (called while MainMenu builds)
    static func apply(_ id: String, to item: NSMenuItem) {
        let b = binding(id)
        item.keyEquivalent = b.key
        item.keyEquivalentModifierMask = b.mods
    }

    /// Human-readable description (settings window display: "⇧⌘F")
    static func display(_ id: String) -> String {
        let b = binding(id)
        guard !b.key.isEmpty else { return "—" }
        var out = ""
        if b.mods.contains(.control) { out += "⌃" }
        if b.mods.contains(.option) { out += "⌥" }
        if b.mods.contains(.shift) { out += "⇧" }
        if b.mods.contains(.command) { out += "⌘" }
        return out + symbolName(for: b.key)
    }

    private static func symbolName(for key: String) -> String {
        switch key {
        case " ": "Space"
        case "\t": "⇥"
        case "\u{8}", "\u{7F}": "⌫"
        case "\u{F700}": "↑"
        case "\u{F701}": "↓"
        case "\u{F702}": "←"
        case "\u{F703}": "→"
        case "\u{F708}": "F5"
        case "\u{F709}": "F6"
        default: key.uppercased()
        }
    }

    /// Rebuild the main menu after a change so it takes effect at once
    static func rebuildMenus() {
        NSApp.mainMenu = MainMenu.build()
    }
}
