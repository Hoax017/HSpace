import Foundation
import HSpaceContracts
import DirectoryReader
import DirectoryWatch
import FolderSize
import IconThumb

/// App-wide shared engine instances (constructed once, injected globally): FolderSize's concurrency limit (=2) and cache apply globally,
/// and IconThumb's LRU thumbnail cache is reused across panes and tabs. Both are Sendable, so static storage is safe.
enum Engines {
    static let folderSize = FolderSize()
    static let iconThumb = IconThumb()
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

    var includeHidden = false { didSet { reload() } }
    var sort = SortSpec() { didSet { reload() } }

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
    }

    func navigate(to url: URL) {
        directory = url
        lastAppliedGeneration = 0  // Reset the generation baseline for the new directory
        startWatching()            // Stop the old stream and open a new one
        reload()
    }

    func reload() {
        if watcher == nil { startWatching() }  // Start watching on first load (loadView → reload)
        loadTask?.cancel()
        isLoading = true
        let request = ReadRequest(directory: directory, includeHidden: includeHidden, sort: sort)
        loadTask = Task { [weak self, reader] in
            do {
                let snap = try await reader.load(request)
                guard let self, !Task.isCancelled else { return }
                guard snap.generation > self.lastAppliedGeneration,
                      snap.directory == self.directory else { return }
                self.lastAppliedGeneration = snap.generation
                self.items = snap.items
                self.isLoading = false
                self.notifyUpdate()
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
