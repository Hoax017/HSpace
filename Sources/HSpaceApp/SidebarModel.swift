import AppKit
import HSpaceContracts
import VolumeInfo
import BookmarkStore
import SidebarColors

/// Sidebar tree model: bookmarks (BookmarkStore, including starting location seeds) + iCloud + locations (VolumeInfo).
/// The stash shelf (StashStore) is shown in its own area, not in the outline. NSOutlineView needs reference identity, so nodes are classes.
@MainActor
final class SidebarGroupNode {
    /// Group kind; rawValue is the persistence key for group order (Preferences.sidebarGroupOrder / drag pasteboard)
    enum Kind: String { case bookmarks, icloud, volumes }
    let kind: Kind
    let title: String
    var children: [SidebarLeafNode] = []

    init(kind: Kind, title: String) {
        self.kind = kind
        self.title = title
    }
}

@MainActor
final class SidebarLeafNode {
    enum Payload {
        case place(URL)
        case bookmark(BookmarkItem)
        case volume(VolumeItem)
    }
    let payload: Payload
    let title: String
    let icon: NSImage
    /// Navigation target; nil when a bookmark's target is lost (UI grays it out)
    let url: URL?
    let subtitle: String?
    /// Title color override (non-navigation rows such as action rows are not grayed for url==nil)
    let titleColor: NSColor?
    /// Icon tint (Finder-style blue favorites icon)
    let tint: NSColor?
    /// Key of this item's colour in the store
    let colorKey: String
    /// The colour the owner gave this item, not one from a palette
    let chosenColor: SidebarColor?

    init(payload: Payload, title: String, icon: NSImage, url: URL?, subtitle: String? = nil,
         titleColor: NSColor? = nil, tint: NSColor? = nil, colorKey: String = "", chosenColor: SidebarColor? = nil) {
        self.payload = payload
        self.title = title
        self.icon = icon
        self.url = url
        self.subtitle = subtitle
        self.titleColor = titleColor
        self.tint = tint
        self.colorKey = colorKey
        self.chosenColor = chosenColor
    }
}

/// Icon and tint of a row once its colour is applied
@MainActor
private struct SidebarRowLook {
    var icon: NSImage
    var tint: NSColor?
    var chosen: SidebarColor?

    /// A real file icon cannot be tinted, so a coloured row swaps it for a symbol that can
    init(key: String, index: Int, settings: SidebarColorSettings, icon: NSImage, tint: NSColor?, symbol: String) {
        self.icon = icon
        self.tint = tint
        chosen = settings.items[key]
        guard let color = settings.color(for: key, index: index) else { return }
        self.tint = color.nsColor
        if !icon.isTemplate, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            image.size = NSSize(width: 16, height: 16)
            self.icon = image
        }
    }
}

@MainActor
final class SidebarModel {
    let bookmarkStore: BookmarkStore
    let colors: any SidebarColorStoring
    private let volumeInfo = VolumeInfo()

    /// Stash shelf controller (injected by MainWindowController; consumed by the StashShelfView area since M14)
    var stash: StashShelfController?

    private(set) var groups: [SidebarGroupNode] = []
    var onChange: (() -> Void)?
    private var volumeWatchTask: Task<Void, Never>?

    init(bookmarkStore: BookmarkStore, colors: (any SidebarColorStoring)? = nil) {
        self.bookmarkStore = bookmarkStore
        self.colors = colors ?? SidebarColorsHost.store
    }

    func start() {
        // Starting location seeds: on a fresh install/no bookmarks.json, inject known personal directories as bookmarks (one-time, idempotent in the pod)
        Task { [weak self] in
            guard let self else { return }
            await self.bookmarkStore.seedIfEmpty(Self.seedPlaces())
            // I-14 one-time reseed: old plain-array archives (non-empty counted as "already seeded") meant default seeds were never injected;
            // merge missing items once; after that, seeds the user deletes stay deleted, and "Restore Default Bookmarks" in settings can bring them back any time
            let seedsMergedKey = TestIsolation.defaultsKey("seedsMergedV2")
            if !UserDefaults.standard.bool(forKey: seedsMergedKey) {
                await self.bookmarkStore.restoreMissingSeeds(Self.seedPlaces())
                UserDefaults.standard.set(true, forKey: seedsMergedKey)
            }
            ProblemAlert.show(await self.bookmarkStore.takeProblem())
            ProblemAlert.show(self.colors.takeProblem())
            self.rebuild()
        }
        // Auto-refresh on volume mount/unmount
        volumeWatchTask = Task { [weak self] in
            guard let self else { return }
            for await _ in self.volumeInfo.changes() {
                self.rebuild()
            }
        }
    }

    // The model shares the window's lifetime; call stop() to stop the watcher early
    func stop() { volumeWatchTask?.cancel() }

    /// Entry for "Restore Default Bookmarks" in settings (I-14): refills missing seeds and refreshes.
    /// A failed write also returns 0 from the store, so the count alone cannot be shown as a result.
    func restoreDefaultSeeds() async -> Result<Int, BookmarkError> {
        await restoreSeeds(Self.seedPlaces())
    }

    func restoreSeeds(_ seeds: [(URL, String)]) async -> Result<Int, BookmarkError> {
        let added = await bookmarkStore.restoreMissingSeeds(seeds)
        rebuild()
        if let problem = await bookmarkStore.takeProblem() { return .failure(problem) }
        return .success(added)
    }

    func eject(_ item: VolumeItem) throws {
        try volumeInfo.eject(item.url)
    }

    func rebuild() {
        Task { [weak self] in
            guard let self else { return }
            let bookmarks = await self.bookmarkStore.all()
            self.applyRebuild(bookmarks: bookmarks)
        }
    }

    private func applyRebuild(bookmarks: [BookmarkItem]) {
        // Bookmark group: starting location seeds stack with user bookmarks. Known paths prefer Finder's original sidebar icons (CoreTypes templates),
        // then SF Symbol + symbol blue, otherwise the real file icon.
        let settings = colors.settings()
        let bookmarkGroup = SidebarGroupNode(kind: .bookmarks, title: L10n.t("sidebar.bookmarks"))
        bookmarkGroup.children = bookmarks.enumerated().map { index, item in
            let url = bookmarkStore.resolve(item)
            let icon: NSImage
            var tint: NSColor? = nil
            if let url, let finder = Self.finderSidebarIcon(url: url) {
                icon = finder
                tint = .systemBlue
            } else if let url, let (symbol, color) = Self.symbolFor(url: url),
               let symImage = NSImage(systemSymbolName: symbol, accessibilityDescription: item.name) {
                icon = symImage
                tint = color
            } else {
                icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
                    ?? NSWorkspace.shared.icon(for: .folder)
            }
            icon.size = NSSize(width: 16, height: 16)
            let key = SidebarItemKey.bookmark(item.id)
            let look = SidebarRowLook(key: key, index: index, settings: settings, icon: icon, tint: tint, symbol: "folder.fill")
            return SidebarLeafNode(payload: .bookmark(item), title: item.name, icon: look.icon, url: url, tint: look.tint,
                                   colorKey: key, chosenColor: look.chosen)
        }

        // Separate iCloud group (same structure as QSpace): has an entry and shows only if the iCloud Drive directory exists
        let icloudGroup = SidebarGroupNode(kind: .icloud, title: L10n.t("sidebar.icloud.section"))
        let icloudURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if FileManager.default.fileExists(atPath: icloudURL.path) {
            let icon = NSImage(systemSymbolName: "icloud", accessibilityDescription: L10n.t("sidebar.icloud"))
                ?? NSWorkspace.shared.icon(for: .folder)
            icon.size = NSSize(width: 16, height: 16)
            let key = SidebarItemKey.place(path: icloudURL.path)
            let look = SidebarRowLook(key: key, index: 0, settings: settings, icon: icon, tint: .systemBlue, symbol: "icloud")
            icloudGroup.children = [SidebarLeafNode(payload: .place(icloudURL),
                                                    title: L10n.t("sidebar.icloud"), icon: look.icon,
                                                    url: icloudURL, tint: look.tint, colorKey: key, chosenColor: look.chosen)]
        }

        let volumeGroup = SidebarGroupNode(kind: .volumes, title: L10n.t("sidebar.volumes"))
        volumeGroup.children = volumeInfo.volumes().enumerated().map { index, vol in
            let icon = NSWorkspace.shared.icon(forFile: vol.url.path)
            icon.size = NSSize(width: 16, height: 16)
            // Read-only volumes (DMGs etc.) have 0 available capacity: show "Read Only" rather than a misleading "0 KB available"
            let subtitle: String?
            if vol.availableCapacity > 0 {
                let free = ByteCountFormatter.string(fromByteCount: vol.availableCapacity, countStyle: .file)
                subtitle = String(format: L10n.t("sidebar.available"), free)
            } else {
                subtitle = L10n.t("sidebar.readOnly")
            }
            let key = SidebarItemKey.place(path: vol.url.path)
            let look = SidebarRowLook(key: key, index: index, settings: settings, icon: icon, tint: nil, symbol: "externaldrive.fill")
            return SidebarLeafNode(payload: .volume(vol), title: vol.name, icon: look.icon, url: vol.url,
                                   subtitle: subtitle, tint: look.tint, colorKey: key, chosenColor: look.chosen)
        }

        // Emit groups in Preferences.sidebarGroupOrder order (user request: bookmarks can be dragged to the top).
        // An empty iCloud group is not shown; groups missing from the order list are appended in a fixed order (backward compatibility/new groups).
        var available: [String: SidebarGroupNode] = [
            SidebarGroupNode.Kind.bookmarks.rawValue: bookmarkGroup,
            SidebarGroupNode.Kind.volumes.rawValue: volumeGroup,
        ]
        if !icloudGroup.children.isEmpty {
            available[SidebarGroupNode.Kind.icloud.rawValue] = icloudGroup
        }
        var ordered: [SidebarGroupNode] = []
        for key in Preferences.sidebarGroupOrder {
            if let g = available.removeValue(forKey: key) { ordered.append(g) }
        }
        for key in [SidebarGroupNode.Kind.bookmarks.rawValue,
                    SidebarGroupNode.Kind.icloud.rawValue,
                    SidebarGroupNode.Kind.volumes.rawValue] {
            if let g = available.removeValue(forKey: key) { ordered.append(g) }
        }
        groups = ordered
        onChange?()
    }

    /// Starting location seed candidates (known personal locations; excludes iCloud, which has its own section). Included only if they exist.
    /// Names are given here (the BookmarkStore pod has no L10n), aligned with the later path mapping in symbolFor.
    static func seedPlaces() -> [(URL, String)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates: [(URL, String)] = [
            (home, L10n.t("sidebar.home")),
            (home.appendingPathComponent("Desktop"), L10n.t("sidebar.desktop")),
            (home.appendingPathComponent("Documents"), L10n.t("sidebar.documents")),
            (home.appendingPathComponent("Movies"), L10n.t("sidebar.movies")),
            (home.appendingPathComponent("Music"), L10n.t("sidebar.music")),
            (home.appendingPathComponent("Pictures"), L10n.t("sidebar.pictures")),
            (home.appendingPathComponent("Downloads"), L10n.t("sidebar.downloads")),
            (URL(fileURLWithPath: "/Applications"), L10n.t("sidebar.applications")),
        ]
        return candidates.filter { FileManager.default.fileExists(atPath: $0.0.path) }
    }

    /// Known home locations -> (SF Symbol, symbol blue). Matched while rendering bookmark rows: a hit uses the blue symbol, otherwise the real folder icon.
    static func symbolFor(url: URL) -> (String, NSColor)? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let map: [(URL, String)] = [
            (home, "house"),
            (home.appendingPathComponent("Desktop"), "desktopcomputer"),
            (home.appendingPathComponent("Documents"), "doc"),
            (home.appendingPathComponent("Movies"), "film"),
            (home.appendingPathComponent("Music"), "music.note"),
            (home.appendingPathComponent("Pictures"), "photo"),
            (home.appendingPathComponent("Downloads"), "arrow.down.circle"),
            // /Applications is left out of the map: it uses NSWorkspace's real folder icon (the original A-tools badge, I-20 user request)
        ]
        let target = url.standardizedFileURL.path
        for (u, symbol) in map where u.standardizedFileURL.path == target {
            return (symbol, .systemBlue)
        }
        return nil
    }

    /// Finder's original sidebar icons (I-20b user request for the "original"): reads Sidebar*.icns directly from the public CoreTypes
    /// resources (the same template images Finder uses), isTemplate tints with the theme.
    /// Takes priority over the approximate SF mapping; a missing file (system version differences) falls back automatically.
    static func finderSidebarIcon(url: URL) -> NSImage? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let map: [(URL, String)] = [
            (home, "SidebarHomeFolder"),
            (home.appendingPathComponent("Desktop"), "SidebarDesktopFolder"),
            (home.appendingPathComponent("Documents"), "SidebarDocumentsFolder"),
            (home.appendingPathComponent("Movies"), "SidebarMoviesFolder"),
            (home.appendingPathComponent("Music"), "SidebarMusicFolder"),
            (home.appendingPathComponent("Pictures"), "SidebarPicturesFolder"),
            (home.appendingPathComponent("Downloads"), "SidebarDownloadsFolder"),
            (URL(fileURLWithPath: "/Applications"), "SidebarApplicationsFolder"),
        ]
        let target = url.standardizedFileURL.path
        for (u, name) in map where u.standardizedFileURL.path == target {
            let path = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/\(name).icns"
            guard let img = NSImage(contentsOfFile: path) else { return nil }
            img.isTemplate = true
            return img
        }
        return nil
    }
}
