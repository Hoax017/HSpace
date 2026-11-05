import Foundation
import HSpaceContracts

// TrashLedger pod's sole public contract surface (Axiom 3): the single source of truth for "Put Back".
//
// Why we must keep our own ledger: macOS put-back metadata lives in Finder's private store and **cannot be read**.
// Measured on a real machine (2026-09-07): the only extended attribute on Trash items is `com.apple.provenance` (empty, unrelated to origin);
// `mdls` has no origin clue; even Finder's own AppleScript `original item` returns -1728.
// So "Put Back" can only cover **items HSpace itself deleted**: items deleted by other apps have no record,
// and the menu item must honestly be disabled rather than pretend it can restore them.

public struct TrashLedgerEntry: Sendable, Hashable, Codable {
    /// Location inside Trash (key)
    public let trashedPath: String
    /// Original path before deletion
    public let originalPath: String
    /// Time recorded (used to clean up stale entries)
    public let recordedAt: Date
    /// Volume that holds the Trash item, to tell "deleted" from "volume not mounted".
    /// nil for ledgers written by older versions and for volumes without a UUID.
    public let volumeUUID: String?

    public init(trashedPath: String, originalPath: String, recordedAt: Date, volumeUUID: String? = nil) {
        self.trashedPath = trashedPath
        self.originalPath = originalPath
        self.recordedAt = recordedAt
        self.volumeUUID = volumeUUID
    }
}

public struct TrashLedgerError: ClassifiedError, LocalizedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String
    /// What `localizedDescription` gives on `any Error`, which is how the app receives it
    public var errorDescription: String? { localizedDescription }

    init(_ cls: ErrorClass, _ message: String) {
        self.errorClass = cls
        self.localizedDescription = message
    }
}

/// "Not into the Trash": a copy or move into a Trash would leave items with no ledger record and no undo.
/// The node has no idea where Trash lives: the caller supplies the roots.
public enum TrashGuard {
    public static func isInside(_ url: URL, anyOf roots: [URL]) -> Bool {
        let path = physicalPath(url)
        return roots.contains { root in
            let r = physicalPath(root)
            return path == r || path.hasPrefix(r.hasSuffix("/") ? r : r + "/")
        }
    }

    /// Real location with symlinks resolved; the spelled path when it cannot be resolved (it does not exist).
    private static func physicalPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// What a move back from the Trash really did. Decided from the receipt and the disk, never assumed.
public enum TrashRestoreStep: Sendable, Equatable {
    /// The item is still in the Trash: the move failed, was cancelled, or the user chose Skip.
    case notRestored
    /// The item left the Trash and needs no further action. `at` is nil when it joined what was already at
    /// that path, by replace or merge: that path then holds more than this item, so redo must not trash it.
    case restored(at: URL?)
    /// The item landed under its Trash name and must be renamed back.
    case rename(landed: URL, to: String)
}

public enum TrashRestorePolicy {
    /// Where the move puts the item when there is no conflict.
    public static func landedURL(of item: TrashedItem) -> URL {
        item.original.deletingLastPathComponent()
            .appendingPathComponent(item.trashed.lastPathComponent, isDirectory: false)
    }

    /// Whether anything is at this path, counting a dangling symlink as present.
    public static func isOccupied(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// Decides the follow-up after the move. The receipt says where the item landed. `landedWasOccupied` is
    /// `isOccupied(landedURL(of:))` sampled **before** the move: when it is true the file there may be unrelated
    /// and must never be renamed. `filesDone` is not a signal, because moving an empty folder reports 0.
    public static func step(after receipt: OperationReceipt?, of item: TrashedItem,
                            landedWasOccupied: Bool) -> TrashRestoreStep {
        // Skip also ends cleanly, so the receipt alone cannot prove the item left the Trash
        guard let receipt, receipt.failures.isEmpty, !isOccupied(item.trashed),
              let landed = receipt.createdURLs.first else { return .notRestored }
        if landedWasOccupied {
            return .restored(at: landed == landedURL(of: item) ? nil : landed)
        }
        guard landed.lastPathComponent != item.original.lastPathComponent else { return .restored(at: landed) }
        return .rename(landed: landed, to: item.original.lastPathComponent)
    }
}
