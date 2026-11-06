import AppKit
import BookmarkStore
import Frecency
import QuickLocations

/// The list behind Go > Quick Locations and Go to Bookmark: what the sidebar shows at once, recent folders as they arrive
@MainActor
final class QuickLocationsModel {
    private let fixed: [QuickLocation]
    private var recents: [QuickLocation] = []
    private let home: URL

    init(fixed: [QuickLocation], home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.fixed = fixed
        self.home = home
    }

    func setRecents(_ recents: [QuickLocation]) { self.recents = recents }

    func matches(_ query: String) -> [QuickLocation] {
        let found = QuickLocationList.filter(QuickLocationList.merge(fixed, recents), query: query, match: Self.match)
        guard let typed = QuickLocationList.typedPath(query, home: home) else { return found }
        let entry = QuickLocation(kind: .typed, title: (typed as NSString).abbreviatingWithTildeInPath, path: typed)
        return [entry] + found.filter { $0.path != typed }
    }

    func rows(_ query: String) -> [QuickRow] { matches(query).map(Self.row) }

    func location(for id: String, query: String) -> QuickLocation? {
        matches(query).first { $0.id == id }
    }

    static let match: QuickLocationList.Match = { query, name, path in
        SearchRanking.matchScore(query: query, name: name, path: path)
    }

    static func row(_ location: QuickLocation) -> QuickRow {
        QuickRow(id: location.id, title: location.title, subtitle: (location.path as NSString).abbreviatingWithTildeInPath,
                 symbol: symbol(location.kind), trailing: L10n.t("quick.kind.\(location.kind.rawValue)"))
    }

    private static func symbol(_ kind: QuickLocationKind) -> String {
        switch kind {
        case .bookmark: "bookmark"
        case .place: "icloud"
        case .volume: "internaldrive"
        case .recent: "clock"
        case .typed: "arrow.right.circle"
        }
    }

    /// Recent folders that still exist, most used first. Off the main actor: a stalled disk must not stall typing.
    static func recentFolders(from store: FrecencyStore?, now: Date = Date()) async -> [QuickLocation] {
        guard let store else { return [] }
        let scores = await store.snapshot().mapValues { SearchRanking.frecencyScore($0, now: now) }
        let existing = await QuickLocationList.existingFolders(QuickLocationList.topPaths(scores))
        return existing.map { path in
            QuickLocation(kind: .recent, title: path == "/" ? "/" : (path as NSString).lastPathComponent,
                          path: path, habit: scores[path] ?? 0)
        }
    }
}

extension SidebarModel {
    /// Sidebar locations as they stand, skipping bookmarks whose target is lost
    func quickLocations(bookmarksOnly: Bool) -> [QuickLocation] {
        // Fixed order, whatever order the owner gave the sidebar groups
        let kinds: [(SidebarGroupNode.Kind, QuickLocationKind)] = [(.bookmarks, .bookmark), (.icloud, .place), (.volumes, .volume)]
        return kinds.filter { !bookmarksOnly || $0.0 == .bookmarks }.flatMap { group, kind in
            (groups.first { $0.kind == group }?.children ?? []).compactMap { leaf in
                leaf.url.map { QuickLocation(kind: kind, title: leaf.title, path: $0.path) }
            }
        }
    }
}

extension MainWindowController {
    @objc func showQuickLocations(_ sender: Any?) {
        presentLocations(bookmarksOnly: false, placeholder: L10n.t("quick.locations.placeholder"))
    }

    @objc func showBookmarkPanel(_ sender: Any?) {
        presentLocations(bookmarksOnly: true, placeholder: L10n.t("quick.bookmarks.placeholder"))
    }

    private func presentLocations(bookmarksOnly: Bool, placeholder: String) {
        let model = QuickLocationsModel(fixed: sidebar.model.quickLocations(bookmarksOnly: bookmarksOnly))
        let panel = QuickPanelController.shared
        let store = bookmarksOnly ? nil : coordinator.frecencyStore
        let recents = Task {
            let folders = await QuickLocationsModel.recentFolders(from: store)
            guard !Task.isCancelled else { return }
            model.setRecents(folders)
            panel.refresh()
        }
        panel.show(QuickPanelContent(placeholder: placeholder, rows: model.rows, choose: { [weak self] row, modifiers in
            // Picked from what was on screen, so the row's own text is enough for a typed path too
            self?.go(toPath: row.id, newTab: modifiers.contains(.command))
        }, onClose: { recents.cancel() }), over: window)
    }

    /// The target is checked here because a bookmark or a recent folder may be gone by now
    func go(toPath path: String, newTab: Bool) {
        Task { [weak self] in
            let status = await QuickLocationList.status(of: path)
            self?.finishGo(to: URL(fileURLWithPath: path), status: status, newTab: newTab)
        }
    }

    func finishGo(to url: URL, status: QuickLocationStatus, newTab: Bool) {
        switch status {
        case .missing:
            Toast.show(L10n.f("quick.missing", (url.path as NSString).abbreviatingWithTildeInPath), in: window)
        case .file:
            if newTab { openWorkspaceTab(at: url.deletingLastPathComponent()) }
            revealSearchHit(url)
        case .folder:
            if newTab {
                openWorkspaceTab(at: url)
            } else {
                grid.activePane.navigate(to: url)
                window?.makeFirstResponder(grid.activePane.focusTarget)
            }
        }
    }
}
