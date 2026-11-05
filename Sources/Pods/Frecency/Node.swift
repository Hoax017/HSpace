import Foundation
import HSpaceContracts

/// Sole Commit Owner of authoritative frecency state (actor serial commits, BG-5/BG-8 scoped to a single process).
/// Records "which paths the user opened or entered across the app, how often, how recently", for focused search to sort by habit (M28).
/// Storage directory is constructor-injected (Axiom 2, no global singleton): the app passes Application Support, tests pass a temp directory.
public actor FrecencyStore {
    private let fileURL: URL
    private var entries: [String: FrecencyEntry] = [:]
    private var loaded = false
    /// Capacity cap: over the cap, evict the lowest-scoring batch (prevents unbounded growth; far from reached in daily use)
    private let maxEntries: Int
    /// Why the file at fileURL could not be loaded, while it still sits there: it must be moved aside before any write
    private var unusableFileReason: String?
    /// Failure no call could throw to its caller, waiting for takeProblem()
    private var problem: FrecencyError?

    public init(directory: URL, maxEntries: Int = 5000) {
        self.fileURL = directory.appendingPathComponent("frecency.json")
        self.maxEntries = maxEntries
    }

    // MARK: Recording (opening files, entering folders and search navigation all go through here)

    /// Records one access: normalizes the path (standardized), count +1, refreshes lastAccess. now is injected for deterministic tests.
    public func record(_ url: URL, now: Date = Date()) {
        ensureLoaded()
        let key = url.standardizedFileURL.path
        var e = entries[key] ?? FrecencyEntry(count: 0, lastAccess: now)
        e.count += 1
        e.lastAccess = now
        entries[key] = e
        pruneIfNeeded(now: now)
        persist()
    }

    // MARK: Queries (for search ranking)

    /// Sort snapshot: fetches all entries at once; the UI scores each hit from it synchronously (frecency is stable during a search).
    public func snapshot() -> [String: FrecencyEntry] {
        ensureLoaded()
        return entries
    }

    /// Current frecency score of one path (convenience; equivalent to SearchRanking.frecencyScore(snapshot[path])).
    public func score(forPath path: String, now: Date = Date()) -> Double {
        ensureLoaded()
        guard let e = entries[path] else { return 0 }
        return SearchRanking.frecencyScore(e, now: now)
    }

    public func count() -> Int {
        ensureLoaded()
        return entries.count
    }

    /// Hands over the last unreported failure once, for the app to show (for example a file that was kept aside at load).
    public func takeProblem() -> FrecencyError? {
        ensureLoaded()
        defer { problem = nil }
        return problem
    }

    // MARK: Private: load / evict / atomic persistence

    private func ensureLoaded() {
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
            entries = try JSONDecoder().decode([String: FrecencyEntry].self, from: data)
        } catch {
            setAsideUnusableFile(because: "the file is damaged")
        }
    }

    /// Moves a file that cannot be loaded to `<name>.corrupt-<UUID>` so that no later write replaces it.
    /// Returns the error while the file stays in place: nothing may be written then, and the next write retries.
    @discardableResult
    private func setAsideUnusableFile(because reason: String? = nil) -> FrecencyError? {
        guard let reason = reason ?? unusableFileReason else { return nil }
        unusableFileReason = reason
        let kept = fileURL.appendingPathExtension("corrupt-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: fileURL, to: kept)
        } catch {
            let failure = FrecencyError(.external, "The history of opened paths could not be read (\(reason)) and the file could not be moved aside, so changes will not be saved: \(error.localizedDescription)")
            problem = failure
            return failure
        }
        unusableFileReason = nil
        problem = FrecencyError(.external, "The history of opened paths could not be read (\(reason)). The file was kept at \(kept.path).")
        return nil
    }

    private func pruneIfNeeded(now: Date) {
        guard entries.count > maxEntries else { return }
        // Ascending by score, evict the lowest until back at 90% of the cap (clears a batch at once, avoiding a sort on every record)
        let target = maxEntries * 9 / 10
        let ranked = entries.sorted { SearchRanking.frecencyScore($0.value, now: now) < SearchRanking.frecencyScore($1.value, now: now) }
        for (k, _) in ranked.prefix(entries.count - target) { entries.removeValue(forKey: k) }
    }

    private func persist() {
        guard setAsideUnusableFile() == nil else { return }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Atomic replace: crash-safe (on persistence failure keep in-memory state and retry on the next record; frecency is non-critical, degrades silently)
        try? data.write(to: fileURL, options: .atomic)
    }
}
