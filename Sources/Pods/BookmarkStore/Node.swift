import Foundation
import HSpaceContracts

/// Sole Commit Owner of authoritative bookmark state (actor serial commits, BG-5/BG-8 scoped to a single process).
/// Storage directory is constructor-injected (Axiom 2): the app passes Application Support, tests pass a temp directory.
public actor BookmarkStore {
    private let fileURL: URL
    private var items: [BookmarkItem] = []
    private var loaded = false
    /// Whether start-location seeds have been injected (persisted in Archive; one-time, so a user's clearing is not re-seeded)
    private var seeded = false
    /// Why the file at fileURL could not be loaded, while it still sits there: it must be moved aside before any write
    private var unusableFileReason: String?
    /// Failure no call could throw to its caller, waiting for takeProblem()
    private var problem: BookmarkError?

    /// On-disk structure (seeded flag + entries). Old archives are a plain [BookmarkItem] array;
    /// on decode failure fall back to the old format (non-empty items count as seeded, backward compatible).
    private struct Archive: Codable {
        var seeded: Bool
        var items: [BookmarkItem]
    }

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("bookmarks.json")
    }

    // MARK: Queries

    public func all() async -> [BookmarkItem] {
        await ensureLoaded()
        return items
    }

    /// Hands over the last unreported failure once, for the app to show (for example a file that was kept aside at load).
    public func takeProblem() async -> BookmarkError? {
        await ensureLoaded()
        defer { problem = nil }
        return problem
    }

    /// Resolves a bookmark target (nil if the target was deleted; the UI grays it out)
    public nonisolated func resolve(_ item: BookmarkItem) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: item.bookmarkData, options: [],
                        relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    // MARK: Mutations (all serialized through this actor + atomic persistence)

    @discardableResult
    public func add(_ url: URL, name: String? = nil) async throws -> BookmarkItem {
        await ensureLoaded()
        let data: Data
        do {
            data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            throw BookmarkError(.external, "Could not create bookmark: \(error.localizedDescription)")
        }
        let item = BookmarkItem(name: name ?? url.lastPathComponent, bookmarkData: data)
        items.append(item)
        try persist()
        return item
    }

    public func remove(_ id: UUID) async throws {
        await ensureLoaded()
        items.removeAll { $0.id == id }
        try persist()
    }

    public func rename(_ id: UUID, to name: String) async throws {
        await ensureLoaded()
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].name = name
        try persist()
    }

    /// Drag reordering
    public func move(from source: Int, to destination: Int) async throws {
        await ensureLoaded()
        guard items.indices.contains(source),
              destination >= 0, destination <= items.count else { return }
        let item = items.remove(at: source)
        items.insert(item, at: min(destination, items.count))
        try persist()
    }

    /// Start-location seeds: writes these directories only if never seeded and currently empty (fresh install / no bookmarks.json).
    /// Seed bookmarks share the stack with user bookmarks: draggable, renamable, removable. The seeded flag is persisted; a second call is an idempotent skip.
    /// Names are supplied by the app layer (the pod has no L10n); targets whose bookmarkData creation fails are skipped (others unaffected).
    public func seedIfEmpty(_ urls: [(URL, String)]) async {
        await ensureLoaded()
        // Already seeded or has entries: only set the flag (idempotent persist), inject no seeds
        guard !seeded, items.isEmpty else {
            if !seeded {
                seeded = true
                persistReportingFailure()
            }
            return
        }
        for (url, name) in urls {
            guard let data = try? url.bookmarkData(options: [],
                                                   includingResourceValuesForKeys: nil,
                                                   relativeTo: nil) else { continue }
            items.append(BookmarkItem(name: name, bookmarkData: data))
        }
        seeded = true
        persistReportingFailure()
    }

    /// Restores missing default seeds (I-14 user semantics: seeds are removable and restorable at any time).
    /// Dedups by resolved standardized path: existing targets are skipped, only missing ones are added; returns the number actually added.
    /// A failed write adds nothing and returns 0, with the error waiting in takeProblem().
    /// Both the settings window's "Restore Default Bookmarks" and the app layer's one-time backfill for old archives go through here.
    @discardableResult
    public func restoreMissingSeeds(_ urls: [(URL, String)]) async -> Int {
        await ensureLoaded()
        let existing = Set(items.compactMap { resolve($0)?.standardizedFileURL.path })
        var added = 0
        for (url, name) in urls where !existing.contains(url.standardizedFileURL.path) {
            guard let data = try? url.bookmarkData(options: [],
                                                   includingResourceValuesForKeys: nil,
                                                   relativeTo: nil) else { continue }
            items.append(BookmarkItem(name: name, bookmarkData: data))
            added += 1
        }
        guard added > 0 else { return 0 }
        let wasSeeded = seeded
        seeded = true
        do {
            try persist()
        } catch {
            items.removeLast(added)
            seeded = wasSeeded
            problem = error as? BookmarkError
            return 0
        }
        return added
    }

    // MARK: Private: loading and atomic persistence

    private func ensureLoaded() async {
        guard !loaded else { return }
        loaded = true
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            return
        } catch {
            setAsideUnusableFile(because: error.localizedDescription)
            return
        }
        // New structure (Archive) first; fall back to the old plain array: non-empty items count as seeded (backward compatible)
        if let archive = try? JSONDecoder().decode(Archive.self, from: data) {
            items = archive.items
            seeded = archive.seeded
        } else if let legacy = try? JSONDecoder().decode([BookmarkItem].self, from: data) {
            items = legacy
            seeded = !legacy.isEmpty
        } else {
            setAsideUnusableFile(because: "the file is damaged")
        }
    }

    /// Moves a file that cannot be loaded to `<name>.corrupt-<UUID>` so that no later write replaces it.
    /// Returns the error while the file stays in place: nothing may be written then, and the next write retries.
    @discardableResult
    private func setAsideUnusableFile(because reason: String? = nil) -> BookmarkError? {
        guard let reason = reason ?? unusableFileReason else { return nil }
        unusableFileReason = reason
        let kept = fileURL.appendingPathExtension("corrupt-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: fileURL, to: kept)
        } catch {
            let failure = BookmarkError(.external, "Bookmarks could not be read (\(reason)) and the file could not be moved aside, so changes will not be saved: \(error.localizedDescription)")
            problem = failure
            return failure
        }
        unusableFileReason = nil
        problem = BookmarkError(.external, "Bookmarks could not be read (\(reason)). The file was kept at \(kept.path).")
        return nil
    }

    /// For writes whose callers have nowhere to receive a throw: the error waits in takeProblem().
    private func persistReportingFailure() {
        do {
            try persist()
        } catch {
            problem = error as? BookmarkError
        }
    }

    private func persist() throws {
        if let blocked = setAsideUnusableFile() { throw blocked }
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Archive(seeded: seeded, items: items))
            // Atomic replace: crash-safe (spec fault matrix: on persistence failure keep in-memory state; the thrown error is shown in place by the caller)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw BookmarkError(.external, "Could not save bookmarks: \(error.localizedDescription)")
        }
    }
}
