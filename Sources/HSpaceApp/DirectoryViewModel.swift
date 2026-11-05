import Foundation
import HSpaceContracts
import DirectoryReader
import DirectoryWatch
import FolderSize
import IconThumb
import FileMetadata
import FileInspector

/// App-wide shared engine instances (constructed once, injected globally): FolderSize's concurrency limit (=2) and cache apply globally,
/// and IconThumb's LRU thumbnail cache is reused across panes and tabs. Both are Sendable, so static storage is safe.
enum Engines {
    static let folderSize = FolderSize()
    static let iconThumb = IconThumb()
    static let metadata = FileMetadata()
    static let inspector = FileInspector()
}

/// Glue for one pane's content: subscribes to the DirectoryReader projection, holds the snapshot, and uses generations to block stale overwrites (spec 3.2).
/// Also holds the DirectoryWatch handle for FSEvents auto-refresh; suspend/resume compares mtimes (north star: zero background power).
/// The presentation layer only consumes reads: this class contains no write-type file operations (BG-1).
@MainActor
final class DirectoryViewModel {
    private let reader = DirectoryReader()
    private let watchFactory = DirectoryWatch()

    private var watcher: DirectoryWatcher?
    private var watchTask: Task<Void, Never>?
    /// Suspended state (spec 3.2 suspended): when true the FSEventStream is really stopped, with no callbacks and no power use
    private(set) var isSuspended = false
    /// Directory mtime at the moment of suspension; compared on resume, reloading only if changed, otherwise no work
    private var suspendedMTime: Date?

    private(set) var directory: URL
    private(set) var items: [FileItem] = []
    private(set) var isLoading = false

    var includeHidden = false { didSet { viewOptionsChanged() } }
    var sort = SortSpec() { didSet { viewOptionsChanged() } }
    /// The user or a command changed the sort or hidden files. Not called for `setViewOptions`.
    var onViewOptionsChange: (() -> Void)?
    private var settingViewOptions = false

    private func viewOptionsChanged() {
        guard !settingViewOptions else { return }
        reload()
        onViewOptionsChange?()
    }

    /// Sets both without reading the folder, for a caller about to navigate or reload
    func setViewOptions(sort: SortSpec, includeHidden: Bool) {
        settingViewOptions = true
        self.sort = sort
        self.includeHidden = includeHidden
        settingViewOptions = false
    }

    /// Tags of this directory's items. Decoration: read after each snapshot, and a failed read only means no dots.
    private(set) var metadata: [URL: ItemMetadata] = [:]
    /// Show only items with one of these tags. Applies to this directory and ends on navigation.
    private(set) var tagFilter: Set<String> = []
    /// Sort by tags instead of `sort`. nil = off. `SortSpec` stays as it is, so turning this off gives the old order back.
    private(set) var tagSortAscending: Bool?
    private var metadataTask: Task<Void, Never>?
    private var metadataHandlers: [() -> Void] = []
    /// Set once in init; only deinit reads it again
    private nonisolated(unsafe) var colorObserver: (any NSObjectProtocol)?
    private nonisolated(unsafe) var rulesObserver: (any NSObjectProtocol)?

    /// Subscribe to tag changes that leave the rows as they are, so a rename in progress is not interrupted
    func addOnMetadataChange(_ handler: @escaping () -> Void) { metadataHandlers.append(handler) }

    /// True when the visible rows depend on the tags, so they must be known before the list shows
    var tagsShapeList: Bool { !tagFilter.isEmpty || tagSortAscending != nil }

    func setTagFilter(_ names: Set<String>) {
        guard names != tagFilter else { return }
        tagFilter = names
        reload()
    }

    func setTagSort(ascending: Bool?) {
        guard ascending != tagSortAscending else { return }
        tagSortAscending = ascending
        reload()
    }

    /// Applies the tag filter and tag sort to a snapshot. Column view passes `applyFilter: false` for parent columns,
    /// where filtering would hide the folders the user drilled through.
    func arranged(_ items: [FileItem], metadata: [URL: ItemMetadata], applyFilter: Bool = true) -> [FileItem] {
        var result = HiddenItems.filter(items, includeHidden: includeHidden)
        if applyFilter, !tagFilter.isEmpty {
            result = result.filter { TagQuery.matches(metadata[$0.url]?.tags ?? [], anyOf: tagFilter) }
        }
        if let ascending = tagSortAscending {
            result = TagQuery.sorted(result, ascending: ascending) { metadata[$0.url]?.tags ?? [] }
        }
        return result
    }

    // M9 multicast: one model is consumed by the list and icon grid views (observers live as long as the tab, so no removal is needed)
    private var updateHandlers: [() -> Void] = []
    private var errorHandlers: [(String) -> Void] = []

    /// Subscribe to snapshot updates (the single hook for multiple views sharing one model)
    func addOnUpdate(_ handler: @escaping () -> Void) { updateHandlers.append(handler) }
    /// Subscribe to in-place error presentation (in-place empty-state banner; no alert storms, per the spec's fault-tolerance matrix)
    func addOnError(_ handler: @escaping (String) -> Void) { errorHandlers.append(handler) }

    private func notifyUpdate() { updateHandlers.forEach { $0() } }
    private func notifyError(_ message: String) { errorHandlers.forEach { $0(message) } }

    private var lastAppliedGeneration: UInt64 = 0
    private var loadTask: Task<Void, Never>?

    init(directory: URL) {
        self.directory = directory
        colorObserver = NotificationCenter.default.addObserver(
            forName: .hspaceFileColorsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.metadataHandlers.forEach { $0() } }
        }
        rulesObserver = NotificationCenter.default.addObserver(
            forName: .hspaceHiddenRulesChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func navigate(to url: URL) {
        directory = url
        tagFilter = []
        metadata = [:]
        lastAppliedGeneration = 0  // Reset the generation baseline for the new directory
        startWatching()            // Stop the old stream and open a new one
        reload()
    }

    func reload() {
        if watcher == nil { startWatching() }  // Start watching on first load (loadView → reload)
        loadTask?.cancel()
        isLoading = true
        let request = ReadRequest(directory: directory, includeHidden: includeHidden, sort: sort)
        let needsTagsFirst = tagsShapeList
        loadTask = Task { [weak self, reader] in
            do {
                let snap = try await reader.load(request)
                let tags = needsTagsFirst ? try await Engines.metadata.read(snap.items.map(\.url)) : nil
                guard let self, !Task.isCancelled else { return }
                guard snap.generation > self.lastAppliedGeneration,
                      snap.directory == self.directory else { return }
                self.lastAppliedGeneration = snap.generation
                if let tags { self.metadata = tags }
                self.items = self.arranged(snap.items, metadata: self.metadata)
                self.isLoading = false
                self.notifyUpdate()
                if tags == nil { self.refreshMetadata(for: snap.items) }
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isLoading = false
                self.items = []
                self.notifyUpdate()
                self.notifyError(error.localizedDescription)
            }
        }
    }

    /// Reads tags without holding the listing back: the first paint must not wait for one attribute per file on a slow volume.
    private func refreshMetadata(for items: [FileItem]) {
        metadataTask?.cancel()
        let urls = items.map(\.url)
        metadataTask = Task { [weak self] in
            guard let fresh = try? await Engines.metadata.read(urls), let self, !Task.isCancelled,
                  fresh != self.metadata else { return }
            self.metadata = fresh
            self.metadataHandlers.forEach { $0() }
        }
    }

    // MARK: Live refresh (FSEvents) and suspend/resume (spec 3.2: zero power for background tabs/panes is the north star)

    /// Opens a new watch stream (fully stopping the old one first). If FSEventStream creation fails, silently degrades to manual refresh (⌘R), with no crash or alert.
    private func startWatching() {
        stopWatching()
        let w = watchFactory.watch(directory)
        watcher = w
        watchTask = Task { [weak self] in
            for await _ in w.signals {
                guard let self else { return }
                // Directory contents changed: invalidate its FolderSize cache first (this directory's row in the parent listing recomputes next time)
                await Engines.folderSize.invalidate(self.directory)
                self.reload()
            }
        }
        // Directory changed while suspended (rare path): suspend the new stream at once; resume still compares mtimes
        if isSuspended {
            w.suspend()
            suspendedMTime = currentMTime()
        }
    }

    /// Fully stops the stream and finishes the signal task (called on tab close; navigate stops the old stream via startWatching)
    func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
        watcher?.stop()
        watcher = nil
    }

    /// Suspend: really stops the FSEventStream (no callbacks, no power use) and records the directory mtime for comparison on resume
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        watcher?.suspend()
        suspendedMTime = currentMTime()
    }

    /// Resume: restarts the stream; reloads only if the mtime changed, otherwise no work (spec 3.2 suspended → loaded/loading)
    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        watcher?.resume()
        let changed = currentMTime() != suspendedMTime
        suspendedMTime = nil
        if changed {
            Task { await Engines.folderSize.invalidate(directory) }
            reload()
        }
    }

    /// Read-only stat (BG-1 allows reads): the directory's contentModificationDate
    private func currentMTime() -> Date? {
        (try? directory.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    deinit {
        // Safety-net stream teardown (the normal path, closeTab, calls stopWatching explicitly); both are Sendable, so deinit may touch them
        watchTask?.cancel()
        watcher?.stop()
        metadataTask?.cancel()
        if let colorObserver { NotificationCenter.default.removeObserver(colorObserver) }
        if let rulesObserver { NotificationCenter.default.removeObserver(rulesObserver) }
    }
}

extension DirectoryViewModel {
    /// Finds an item's index by URL (the single criterion shared by list, icon and column view positioning).
    /// First an exact compare of standardized paths (directory entry URLs have a trailing slash, those from navigation/search don't; same fix as I-39);
    /// if that fails, falls back to a **case-insensitive** compare: APFS/HFS+ are case-insensitive by default, and paths pasted by users or passed
    /// by third parties often differ in case from disk, so `fileExists` passes while an exact string compare fails, showing up as
    /// a silent failure: "jumped to the parent but nothing is selected".
    func itemIndex(forURL url: URL) -> Int? {
        let target = url.standardizedFileURL.path
        if let exact = items.firstIndex(where: { $0.url.standardizedFileURL.path == target }) {
            return exact
        }
        return items.firstIndex {
            $0.url.standardizedFileURL.path.compare(target, options: .caseInsensitive) == .orderedSame
        }
    }

    /// Whether this directory is the URL's parent (i.e. "the target directory has finished loading"; used to void a pending reveal that missed)
    func isLoadedDirectory(forParentOf url: URL) -> Bool {
        directory.standardizedFileURL.path
            == url.deletingLastPathComponent().standardizedFileURL.path
    }
}
