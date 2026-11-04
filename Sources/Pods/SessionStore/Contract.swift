import Foundation
import HSpaceContracts

// SessionStore pod's sole public contract surface (Axiom 3): sole Commit Owner of the window/layout/pane/tab session snapshot

public struct SessionTab: Sendable, Codable, Equatable {
    public var path: String
    public var sortKey: String
    public var sortAscending: Bool
    public var includeHidden: Bool
    /// View mode raw value (Int raw of icons/list/columns); missing in old archives, nil = list
    public var viewMode: Int?

    public init(path: String, sortKey: String = "name", sortAscending: Bool = true,
                includeHidden: Bool = false, viewMode: Int? = nil) {
        self.path = path
        self.sortKey = sortKey
        self.sortAscending = sortAscending
        self.includeHidden = includeHidden
        self.viewMode = viewMode
    }
}

/// One pane = one browsing context.
///
/// Since v0.19.26 panes no longer have multiple tabs (M13's "per-pane tabs" is retired: the product recognizes only window-level workspace tabs,
/// while the pane tab bar was hidden by default, tabs created there were invisible, and external opens kept piling into them; users reported
/// "⌥⌘T does nothing" and "this doesn't seem to do anything"). External opens now land in workspace tabs, a layer that is visible and closable.
public struct SessionPane: Sendable, Codable, Equatable {
    public var tab: SessionTab

    public init(tab: SessionTab) {
        self.tab = tab
    }

    private enum CodingKeys: String, CodingKey { case tab, tabs, activeTabIndex }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Try the new structure first
        if let t = try? c.decode(SessionTab.self, forKey: .tab) {
            self.tab = t
            return
        }
        // One-time migration of the old structure (multiple tabs per pane): keep only the **active** tab at that time, discard the rest.
        // Do not expand into multiple workspaces: the user's busiest pane has 5 tabs, and expanding all of them would explode into twenty-odd
        // workspaces, not what "removing this layer" should produce.
        let tabs = try c.decode([SessionTab].self, forKey: .tabs)
        let idx = (try? c.decode(Int.self, forKey: .activeTabIndex)) ?? 0
        // An empty array is an impossible state (the old implementation guaranteed at least one tab per pane); if it does occur, use an empty path,
        // caught upstream by "path gone at session restore → fall back to home" (spec.md risk table).
        self.tab = tabs.indices.contains(idx) ? tabs[idx] : (tabs.first ?? SessionTab(path: ""))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tab, forKey: .tab)
    }
}

public struct SessionWindow: Sendable, Codable, Equatable {
    /// PaneLayout.rawValue (UI-layer enums stay out of pod contracts)
    public var layoutRaw: Int
    public var panes: [SessionPane]
    public var activePaneIndex: Int

    public init(layoutRaw: Int, panes: [SessionPane], activePaneIndex: Int) {
        self.layoutRaw = layoutRaw
        self.panes = panes
        self.activePaneIndex = activePaneIndex
    }
}

/// One OS window = a group of workspaces (M17: workspace tabs moved out of native NSWindow tabbing → self-managed).
/// Each workspace reuses the SessionWindow encoding (layout + panes + tabs + paths + sort + view mode).
public struct SessionWorkspaces: Sendable, Codable, Equatable {
    public var workspaces: [SessionWindow]
    public var activeWorkspace: Int

    public init(workspaces: [SessionWindow], activeWorkspace: Int) {
        self.workspaces = workspaces
        self.activeWorkspace = activeWorkspace
    }
}

/// Session snapshot (M17 structure): each windows item = the workspace array inside one window.
/// The old format (each windows item directly a SessionWindow, i.e. "one copy per window") is migrated once on decode:
/// all old windows are wrapped into the workspace array of a **single** window (preserving what M13 flat tabs showed).
public struct SessionSnapshot: Sendable, Codable, Equatable {
    public var windows: [SessionWorkspaces]

    public init(windows: [SessionWorkspaces]) {
        self.windows = windows
    }

    private enum CodingKeys: String, CodingKey { case windows }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Try the new structure first (elements contain the workspaces key)
        if let ws = try? container.decode([SessionWorkspaces].self, forKey: .windows) {
            self.windows = ws
            return
        }
        // Fall back to the old structure: each windows item is a SessionWindow → wrap them all into one window's workspace array
        let legacy = try container.decode([SessionWindow].self, forKey: .windows)
        self.windows = legacy.isEmpty ? [] : [SessionWorkspaces(workspaces: legacy, activeWorkspace: 0)]
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(windows, forKey: .windows)
    }
}

public struct SessionError: ClassifiedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String

    init(_ cls: ErrorClass, _ message: String) {
        self.errorClass = cls
        self.localizedDescription = message
    }
}
