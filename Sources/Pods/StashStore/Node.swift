import Foundation
import HSpaceContracts

/// Sole Commit Owner of authoritative stash shelf state (actor serial commits, BG-5/BG-8 scoped to a single process).
/// Storage directory is constructor-injected (Axiom 2): the app passes Application Support, tests pass a temp directory.
public actor StashStore {
    private let fileURL: URL
    private var items: [StashItem] = []
    private var loaded = false
    /// Why the file at fileURL could not be loaded, while it still sits there: it must be moved aside before any write
    private var unusableFileReason: String?
    /// Failure no call could throw to its caller, waiting for takeProblem()
    private var problem: StashError?

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("stash.json")
    }

    // MARK: Queries

    public func all() async -> [StashItem] {
        await ensureLoaded()
        return items
    }

    /// Hands over the last unreported failure once, for the app to show (for example a file that was kept aside at load).
    public func takeProblem() async -> StashError? {
        await ensureLoaded()
        defer { problem = nil }
        return problem
    }

    /// Resolves a stash target (nil if the target was deleted; the UI grays it out)
    public nonisolated func resolve(_ item: StashItem) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: item.bookmarkData, options: [],
                        relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    // MARK: Mutations (all serialized through this actor + atomic persistence)

    /// Batch add (dedups by path: already stashed paths are silently skipped); returns the items actually added
    @discardableResult
    public func add(_ urls: [URL]) async throws -> [StashItem] {
        await ensureLoaded()
        var seen = Set(items.compactMap { resolve($0)?.standardizedFileURL.path })
        var added: [StashItem] = []
        for url in urls {
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else { continue }
            let data: Data
            do {
                data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            } catch {
                throw StashError(.external, "Could not stash \"\(url.lastPathComponent)\": \(error.localizedDescription)")
            }
            seen.insert(path)
            added.append(StashItem(bookmarkData: data))
        }
        guard !added.isEmpty else { return [] }
        items.append(contentsOf: added)
        try persist()
        return added
    }

    public func remove(ids: [UUID]) async throws {
        await ensureLoaded()
        let removal = Set(ids)
        items.removeAll { removal.contains($0.id) }
        try persist()
    }

    public func clear() async throws {
        await ensureLoaded()
        items = []
        try persist()
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
        do {
            items = try JSONDecoder().decode([StashItem].self, from: data)
        } catch {
            setAsideUnusableFile(because: "the file is damaged")
        }
    }

    /// Moves a file that cannot be loaded to `<name>.corrupt-<UUID>` so that no later write replaces it.
    /// Returns the error while the file stays in place: nothing may be written then, and the next write retries.
    @discardableResult
    private func setAsideUnusableFile(because reason: String? = nil) -> StashError? {
        guard let reason = reason ?? unusableFileReason else { return nil }
        unusableFileReason = reason
        let kept = fileURL.appendingPathExtension("corrupt-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: fileURL, to: kept)
        } catch {
            let failure = StashError(.external, "The stash shelf could not be read (\(reason)) and the file could not be moved aside, so changes will not be saved: \(error.localizedDescription)")
            problem = failure
            return failure
        }
        unusableFileReason = nil
        problem = StashError(.external, "The stash shelf could not be read (\(reason)). The file was kept at \(kept.path).")
        return nil
    }

    private func persist() throws {
        if let blocked = setAsideUnusableFile() { throw blocked }
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(items)
            // Atomic replace: crash-safe (spec fault matrix: on persistence failure keep in-memory state; the thrown error is shown in place by the caller)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw StashError(.external, "Could not save stash shelf:\(error.localizedDescription)")
        }
    }
}
