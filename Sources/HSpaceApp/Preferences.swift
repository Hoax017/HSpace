import Foundation

/// Centralized app-layer preferences (single entry for externalized config, no hard-coding scattered around; the pod layer must not use this type and gets values by constructor injection).
/// All keys are registered here and the settings window renders from this; a new configurable item = one more static property.
@MainActor
enum Preferences {
    private static let d = UserDefaults.standard

    /// Default layout for new windows/workspace tabs (user request: single or dual pane must be configurable)
    static var defaultLayoutRaw: Int {
        get { d.object(forKey: "defaultLayout") as? Int ?? 1 }  // 1 = single pane
        set { d.set(newValue, forKey: "defaultLayout") }
    }

    /// Default view mode for new panes (icons=0/list=1/columns=2)
    static var defaultViewModeRaw: Int {
        get { d.object(forKey: "defaultViewMode") as? Int ?? 1 }  // list
        set { d.set(newValue, forKey: "defaultViewMode") }
    }

    /// Show hidden files by default in new panes
    static var showHiddenByDefault: Bool {
        get { d.bool(forKey: "showHiddenByDefault") }
        set { d.set(newValue, forKey: "showHiddenByDefault") }
    }

    /// Keep folders on top when sorting
    static var foldersFirst: Bool {
        get { d.object(forKey: "foldersFirst") as? Bool ?? true }
        set { d.set(newValue, forKey: "foldersFirst") }
    }

    /// Default terminal ("auto" = iTerm first, falling back to Terminal)
    static var terminalChoice: String {
        get { d.string(forKey: "terminalChoice") ?? "auto" }
        set { d.set(newValue, forKey: "terminalChoice") }
    }

    /// Optional column visibility (Name is always shown); QSpace-style right-click ticks on the column header
    static var visibleColumns: [String] {
        get { d.stringArray(forKey: "visibleColumns") ?? ["dateModified", "size", "kind"] }
        set { d.set(newValue, forKey: "visibleColumns") }
    }

    /// Group the list view by year/month (M26; on by default: users expect grouping when sorting by date).
    /// Applies only when the sort key is date-based (dateModified/created/added); a non-date key or turning it off gives a single flat list.
    static var listGrouping: Bool {
        get { d.object(forKey: "listGrouping") as? Bool ?? true }
        set { d.set(newValue, forKey: "listGrouping") }
    }

    /// Smart focused-search ranking by usage (M28, Listary-style blend of frecency + match quality). On by default;
    /// when off, falls back to the original order (local: nearest to root, global: arrival order).
    static var searchSmartSort: Bool {
        get { d.object(forKey: "searchSmartSort") as? Bool ?? true }
        set { d.set(newValue, forKey: "searchSmartSort") }
    }

    /// Sidebar group order (QSpace semantics, user request: bookmarks can be dragged to the top).
    /// Outline group keys: bookmarks/icloud/volumes (the stash shelf has its own area, not in the outline); reordering by dragging a group header persists here.
    static var sidebarGroupOrder: [String] {
        get { d.stringArray(forKey: "sidebarGroupOrder") ?? ["bookmarks", "icloud", "volumes"] }
        set { d.set(newValue, forKey: "sidebarGroupOrder") }
    }

    // MARK: Archive defaults (ArchiveEngine capability; FileOpsCoordinator builds ArchiveOptions from these)

    /// Default compression format: "zip" / "tar.gz"
    static var archiveFormat: String {
        get { d.string(forKey: "archiveFormat") ?? "zip" }
        set { d.set(newValue, forKey: "archiveFormat") }
    }

    /// Keep originals after compressing (false = move the originals to the Trash after a successful archive)
    static var archiveKeepOriginal: Bool {
        get { d.object(forKey: "archiveKeepOriginal") as? Bool ?? true }
        set { d.set(newValue, forKey: "archiveKeepOriginal") }
    }

    /// Ensure a wrapper folder on extraction (with more than one top-level entry, create a folder of the same name first; ignored for a single entry)
    static var extractCreateWrapper: Bool {
        get { d.object(forKey: "extractCreateWrapper") as? Bool ?? true }
        set { d.set(newValue, forKey: "extractCreateWrapper") }
    }

    /// Keep the archive after extracting (false = move the archive to the Trash after a successful extraction)
    static var extractKeepArchive: Bool {
        get { d.object(forKey: "extractKeepArchive") as? Bool ?? true }
        set { d.set(newValue, forKey: "extractKeepArchive") }
    }

    /// Archive format choices (for the popup)
    static let archiveFormatOptions: [(id: String, nameKey: String)] = [
        ("zip", "settings.archiveFormat.zip"),
        ("tar.gz", "settings.archiveFormat.targz"),
    ]
    // MARK: Behavior (QSpace-aligned subset)

    /// Enter key behavior: "rename" (default, inline rename) / "open" (open the selection)
    static var enterAction: String {
        get { d.string(forKey: "enterAction") ?? "rename" }
        set { d.set(newValue, forKey: "enterAction") }
    }

    /// Backspace key behavior: "ignore" (default) / "back" (go back a step) / "delete" (move to Trash) / "up" (parent folder)
    static var backspaceAction: String {
        get { d.string(forKey: "backspaceAction") ?? "ignore" }
        set { d.set(newValue, forKey: "backspaceAction") }
    }

    /// Drag and drop behavior: "auto" (default, move within a volume, copy across volumes) / "copy" (always copy) / "move" (always move within a volume, still copy across volumes)
    static var dragBehavior: String {
        get { d.string(forKey: "dragBehavior") ?? "auto" }
        set { d.set(newValue, forKey: "dragBehavior") }
    }

    /// Double-click blank list space to go to the parent folder (default false)
    static var doubleClickBlank: Bool {
        get { d.bool(forKey: "doubleClickBlank") }
        set { d.set(newValue, forKey: "doubleClickBlank") }
    }

    /// Default sort key for new panes (name/dateModified/size/kind; applies only to newly created panes)
    static var defaultSortKey: String {
        get { d.string(forKey: "defaultSortKey") ?? "name" }
        set { d.set(newValue, forKey: "defaultSortKey") }
    }

    /// New panes sort ascending by default (default true)
    static var defaultSortAscending: Bool {
        get { d.object(forKey: "defaultSortAscending") as? Bool ?? true }
        set { d.set(newValue, forKey: "defaultSortAscending") }
    }

    /// Workspace tab limit (0 = no limit; >0 means a new workspace over the limit replaces the oldest: removes index 0, same as QSpace).
    /// Since v0.19.26 this is the only tab limit: in-pane tabs are retired.
    static var workspaceTabLimit: Int {
        get { d.integer(forKey: "workspaceTabLimit") }  // unset = 0 = no limit
        set { d.set(newValue, forKey: "workspaceTabLimit") }
    }

    /// Destination when an external open-URL opens a directory: "newWindow" = a new window every time;
    /// any other value (default "newTab", including the old value "activePane") = reuse the existing window with a new **workspace tab**,
    /// pointing the active pane at the target directory. Before v0.19.26 this made a new pane tab in the active pane; that layer is retired.
    static var externalOpenTarget: String {
        get { d.string(forKey: "externalOpenTarget") ?? "newTab" }
        set { d.set(newValue, forKey: "externalOpenTarget") }
    }

    /// "Don't ask again" flag for the automatic Full Disk Access prompt (default false = not dismissed; when not granted, launch prompts once)
    static var fdaPromptDismissed: Bool {
        get { d.bool(forKey: "fdaPromptDismissed") }
        set { d.set(newValue, forKey: "fdaPromptDismissed") }
    }

    // MARK: Appearance (v1 subset of QSpace's appearance options; all apply immediately, refreshed through Theme broadcasts)

    /// Light/dark mode: "system" (follow system, default) / "light" / "dark"
    static var appearanceMode: String {
        get { d.string(forKey: "appearanceMode") ?? "system" }
        set { d.set(newValue, forKey: "appearanceMode") }
    }

    /// Theme accent color (6-digit hex, RRGGBB); nil = follow the system accent color (controlAccentColor)
    static var accentColorHex: String? {
        get { d.string(forKey: "accentColorHex") }
        set {
            if let newValue { d.set(newValue, forKey: "accentColorHex") }
            else { d.removeObject(forKey: "accentColorHex") }
        }
    }

    /// List font size (11/12/13/14, default 12); out-of-range values are clamped to the allowed range
    static var listFontSize: Int {
        get {
            let v = d.object(forKey: "listFontSize") as? Int ?? 12
            return min(14, max(11, v))
        }
        set { d.set(min(14, max(11, newValue)), forKey: "listFontSize") }
    }

    /// Highlight the active pane's address bar (on by default)
    static var activePaneHighlight: Bool {
        get { d.object(forKey: "activePaneHighlight") as? Bool ?? true }
        set { d.set(newValue, forKey: "activePaneHighlight") }
    }

    /// Inactive pane content dimming alpha (0~0.3, default 0 = no dimming); out-of-range values are clamped
    static var inactivePaneDimming: Double {
        get {
            let v = d.object(forKey: "inactivePaneDimming") as? Double ?? 0
            return min(0.3, max(0, v))
        }
        set { d.set(min(0.3, max(0, newValue)), forKey: "inactivePaneDimming") }
    }

    /// Terminal choices (bundle id; auto is a special value)
    static let terminalOptions: [(id: String, nameKey: String)] = [
        ("auto", "settings.terminal.auto"),
        ("com.googlecode.iterm2", "settings.terminal.iterm"),
        ("com.apple.Terminal", "settings.terminal.terminal"),
        ("dev.warp.Warp-Stable", "settings.terminal.warp"),
        ("net.kovidgoyal.kitty", "settings.terminal.kitty"),
    ]
}
