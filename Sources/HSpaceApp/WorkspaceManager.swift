import Foundation
import SessionStore
import TabNavigation

/// Workspace manager (M17: workspace tabs moved out of native NSWindow tabbing and are self-managed).
/// Holds the window's `[SessionWindow]` (each workspace = one complete split layout snapshot) + activeIndex.
/// Pure state and bookkeeping, no UI: MainWindowController drives its single grid from this (switch = snapshot current -> restore target).
@MainActor
final class WorkspaceManager {
    /// All workspace snapshots; the active workspace's live state is fed back by MainWindowController through syncActive before switching
    private(set) var states: [SessionWindow]
    private(set) var activeIndex: Int
    /// Activity history (MRU, first = most recent): closing the active workspace returns to the "previously active" one, not an index neighbor (I-21 user semantics)
    private var recency: TabRecency

    init(initial: SessionWindow) {
        self.states = [initial]
        self.activeIndex = 0
        self.recency = TabRecency(active: 0)
    }

    init(states: [SessionWindow], activeIndex: Int) {
        precondition(!states.isEmpty, "Workspace array must not be empty")
        self.states = states
        self.activeIndex = min(max(0, activeIndex), states.count - 1)
        self.recency = TabRecency(active: self.activeIndex)
    }

    var count: Int { states.count }
    var activeState: SessionWindow { states[activeIndex] }
    /// Every workspace by last use, the active one first
    var recentOrder: [Int] { recency.all(count: states.count) }

    /// Workspace tab title = directory name of the active tab of the workspace's active pane (QSpace semantics)
    func titles() -> [String] { states.map { Self.title(of: $0) } }

    static func title(of w: SessionWindow) -> String {
        guard let path = path(of: w), !path.isEmpty else { return "—" }
        return path == "/" ? "/" : (path as NSString).lastPathComponent
    }

    /// Folder of the workspace's active pane
    static func path(of w: SessionWindow) -> String? {
        let pane = w.panes.indices.contains(w.activePaneIndex) ? w.panes[w.activePaneIndex] : w.panes.first
        return pane?.tab.path
    }

    /// Before switching, feed the grid's live snapshot back into the active slot (otherwise the workspace being left loses unsaved edits)
    func syncActive(_ snapshot: SessionWindow) {
        guard states.indices.contains(activeIndex) else { return }
        states[activeIndex] = snapshot
    }

    /// Append a new workspace and make it active; with limit>0 and over the limit, replace the oldest (remove index 0, QSpace semantics).
    func append(_ w: SessionWindow, limit: Int) {
        states.append(w)
        if limit > 0, states.count > limit {
            let dropped = states.count - limit
            states.removeFirst(dropped)
            recency.removeFirst(dropped)
        }
        activeIndex = states.count - 1
        recency.touch(activeIndex)
    }

    /// Switch to the given workspace (out of range is ignored)
    func switchTo(_ index: Int) {
        guard states.indices.contains(index) else { return }
        activeIndex = index
        recency.touch(index)
    }

    /// Close the given workspace; returns false if it is the last one (the caller should close the window).
    /// Closing the active workspace falls back to the previously active one in the MRU (I-21); closing an inactive one only fixes indices.
    @discardableResult
    func close(at index: Int) -> Bool {
        guard states.count > 1, states.indices.contains(index) else { return false }
        let wasActive = index == activeIndex
        states.remove(at: index)
        recency.remove(at: index)
        if wasActive {
            activeIndex = recency.mostRecent ?? min(index, states.count - 1)
        } else if index < activeIndex {
            activeIndex -= 1
        }
        recency.touch(activeIndex)
        return true
    }

    /// Cycle (⌃⇥ / ⌃⇧⇥)
    func cycle(backward: Bool) {
        guard states.count > 1 else { return }
        activeIndex = (activeIndex + (backward ? -1 : 1) + states.count) % states.count
        recency.touch(activeIndex)
    }
}
