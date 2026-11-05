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
    /// Why the file at fileURL could not be loaded, while it still sits there: it must be moved aside before any write
    private var unusableFileReason: String?
    /// Failure no call could throw to its caller, waiting for takeProblem()
    private var problem: TrashLedgerError?

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

    /// Hands over the last unreported failure once, for the app to show (for example a file that was kept aside at load).
    public func takeProblem() async -> TrashLedgerError? {
        await ensureLoaded()
        defer { problem = nil }
        return problem
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
                                          recordedAt: now,
                                          volumeUUID: Self.volumeUUID(of: p.trashed))
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

    /// Forgets what a permanent delete really removed. Items the receipt lists as failed are still in the
    /// Trash, so they keep their record and stay eligible for Put Back.
    public func forgetErased(_ victims: [URL], receipt: OperationReceipt) async {
        let failed = Set(receipt.failures.map { Self.key($0.url) })
        await forget(victims.filter { !failed.contains(Self.key($0)) })
    }

    /// Closes the record of a restore attempt: dropped only once the item has left the Trash,
    /// so a failed or skipped Put Back can be tried again, including after a restart.
    public func settle(_ step: TrashRestoreStep, for trashedURL: URL) async {
        guard step != .notRestored else { return }
        await forget([trashedURL])
    }

    // MARK: Internals

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

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
        let list: [TrashLedgerEntry]
        do {
            list = try JSONDecoder().decode([TrashLedgerEntry].self, from: data)
        } catch {
            setAsideUnusableFile(because: "the file is damaged")
            return
        }
        var kept: [String: TrashLedgerEntry] = [:]
        var dropped = false
        for e in list {
            // Self-pruning: the item is no longer in Trash (emptied / deleted by another app / already put back), so the entry is void.
            // An item on an unmounted volume is only out of reach: its Put Back must work again after remounting.
            // lstat, because a trashed dangling link is still in the Trash
            if TrashRestorePolicy.isOccupied(URL(fileURLWithPath: e.trashedPath)) || Self.isOnOfflineVolume(e) {
                kept[e.trashedPath] = e
            } else {
                dropped = true
            }
        }
        entries = kept
        if dropped { persist() }
    }

    private static func volumeUUID(of url: URL) -> String? {
        (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
    }

    /// Any doubt answers true: keeping a stale entry is harmless, losing a live one is not.
    private static func isOnOfflineVolume(_ entry: TrashLedgerEntry) -> Bool {
        let fm = FileManager.default
        guard let expected = entry.volumeUUID else {
            // No recorded identity: only the standard mount location can show the volume is away
            let parts = URL(fileURLWithPath: entry.trashedPath).pathComponents
            return parts.count > 3 && parts[1] == "Volumes" && !fm.fileExists(atPath: "/Volumes/" + parts[2])
        }
        // An unmounted volume leaves at most an empty mount folder, which belongs to another volume
        var probe = URL(fileURLWithPath: entry.trashedPath)
        while probe.path != "/", !fm.fileExists(atPath: probe.path) { probe = probe.deletingLastPathComponent() }
        return volumeUUID(of: probe) != expected
    }

    /// Moves a file that cannot be loaded to `<name>.corrupt-<UUID>` so that no later write replaces it.
    /// Returns the error while the file stays in place: nothing may be written then, and the next write retries.
    @discardableResult
    private func setAsideUnusableFile(because reason: String? = nil) -> TrashLedgerError? {
        guard let reason = reason ?? unusableFileReason else { return nil }
        unusableFileReason = reason
        let kept = fileURL.appendingPathExtension("corrupt-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: fileURL, to: kept)
        } catch {
            let failure = TrashLedgerError(.external, "The Put Back records could not be read (\(reason)) and the file could not be moved aside, so changes will not be saved: \(error.localizedDescription)")
            problem = failure
            return failure
        }
        unusableFileReason = nil
        problem = TrashLedgerError(.external, "The Put Back records could not be read (\(reason)). The file was kept at \(kept.path).")
        return nil
    }

    /// Atomic persistence. A failure leaves in-memory state intact, is reported through takeProblem(),
    /// and is retried on the next mutation.
    private func persist() {
        guard setAsideUnusableFile() == nil else { return }
        let list = entries.values.sorted { $0.recordedAt < $1.recordedAt }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(list).write(to: fileURL, options: .atomic)
        } catch {
            problem = TrashLedgerError(.external, "Could not save the Put Back records, so Put Back will not work after a restart: \(error.localizedDescription)")
        }
    }
}
