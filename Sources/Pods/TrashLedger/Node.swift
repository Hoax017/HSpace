import Foundation
import HSpaceContracts

/// Sole Commit Owner of the "Put Back" ledger (actor serial commits + atomic persistence, BG-5/BG-8).
/// Storage directory is constructor-injected (Axiom 2): the app passes Application Support, tests pass a temp directory.
///
/// Self-pruning: on read, drops stale entries whose item no longer exists in Trash, shrinking the file accordingly.
/// A ledger that cannot notice it is out of date is worse than no ledger: it hands out overturned facts as established ones.
public actor TrashLedger {
    private let fileURL: URL
    private var entries: [String: TrashLedgerEntry] = [:]   // trashedPath → entry
    private var loaded = false

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("trash-ledger.json")
    }

    // MARK: Queries

    /// Original path of this Trash item (no record = nil; the caller grays out the menu item)
    public func origin(of trashedURL: URL) async -> URL? {
        await ensureLoaded()
        guard let e = entries[Self.key(trashedURL)] else { return nil }
        return URL(fileURLWithPath: e.originalPath)
    }

    /// Batch lookup (for menu validation: "Put Back" is allowed only when every item has a record)
    public func origins(of trashedURLs: [URL]) async -> [URL: URL] {
        await ensureLoaded()
        var out: [URL: URL] = [:]
        for u in trashedURLs {
            if let e = entries[Self.key(u)] { out[u] = URL(fileURLWithPath: e.originalPath) }
        }
        return out
    }

    public func count() async -> Int {
        await ensureLoaded()
        return entries.count
    }

    // MARK: Mutations

    /// Records a batch of "original path → Trash location" pairs. Repeat records for the same location keep the latest.
    public func record(_ pairs: [(original: URL, trashed: URL)], now: Date = Date()) async {
        guard !pairs.isEmpty else { return }
        await ensureLoaded()
        for p in pairs {
            let k = Self.key(p.trashed)
            entries[k] = TrashLedgerEntry(trashedPath: k,
                                          originalPath: p.original.standardizedFileURL.path,
                                          recordedAt: now)
        }
        persist()
    }

    /// Forgets these locations (call after a successful put-back or a permanent delete)
    public func forget(_ trashedURLs: [URL]) async {
        guard !trashedURLs.isEmpty else { return }
        await ensureLoaded()
        var changed = false
        for u in trashedURLs where entries.removeValue(forKey: Self.key(u)) != nil { changed = true }
        if changed { persist() }
    }

    // MARK: Internals

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    private func ensureLoaded() async {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([TrashLedgerEntry].self, from: data) else { return }
        let fm = FileManager.default
        var kept: [String: TrashLedgerEntry] = [:]
        var dropped = false
        for e in list {
            // Self-pruning: the item is no longer in Trash (emptied / deleted by another app / already put back), so the entry is void
            if fm.fileExists(atPath: e.trashedPath) { kept[e.trashedPath] = e } else { dropped = true }
        }
        entries = kept
        if dropped { persist() }
    }

    /// Atomic persistence (write a temp file, then replace; a write failure leaves in-memory state intact, retried on the next mutation)
    private func persist() {
        let list = entries.values.sorted { $0.recordedAt < $1.recordedAt }
        guard let data = try? JSONEncoder().encode(list) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = fileURL.appendingPathExtension("tmp-\(UUID().uuidString)")
        guard (try? data.write(to: tmp, options: .atomic)) != nil else { return }
        if (try? FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)) == nil {
            // replaceItemAt fails when the target does not exist yet; fall back to moving it over directly
            try? FileManager.default.moveItem(at: tmp, to: fileURL)
        }
    }
}
