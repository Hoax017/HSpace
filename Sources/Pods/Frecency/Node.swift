import Foundation
import NSpaceContracts

/// Sole Commit Owner of authoritative frecency state (actor serial commits, BG-5/BG-8 scoped to a single process).
/// Records "which paths the user opened or entered across the app, how often, how recently", for focused search to sort by habit (M28).
/// Storage directory is constructor-injected (Axiom 2, no global singleton): the app passes Application Support, tests pass a temp directory.
public actor FrecencyStore {
    private let fileURL: URL
    private var entries: [String: FrecencyEntry] = [:]
    private var loaded = false
    /// Capacity cap: over the cap, evict the lowest-scoring batch (prevents unbounded growth; far from reached in daily use)
    private let maxEntries: Int

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

    // MARK: Private: load / evict / atomic persistence

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: FrecencyEntry].self, from: data) else { return }
        entries = decoded
    }

    private func pruneIfNeeded(now: Date) {
        guard entries.count > maxEntries else { return }
        // Ascending by score, evict the lowest until back at 90% of the cap (clears a batch at once, avoiding a sort on every record)
        let target = maxEntries * 9 / 10
        let ranked = entries.sorted { SearchRanking.frecencyScore($0.value, now: now) < SearchRanking.frecencyScore($1.value, now: now) }
        for (k, _) in ranked.prefix(entries.count - target) { entries.removeValue(forKey: k) }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Atomic replace: crash-safe (on persistence failure keep in-memory state and retry on the next record; frecency is non-critical, degrades silently)
        try? data.write(to: fileURL, options: .atomic)
    }
}
