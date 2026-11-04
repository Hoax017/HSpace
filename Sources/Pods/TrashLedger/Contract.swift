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

    public init(trashedPath: String, originalPath: String, recordedAt: Date) {
        self.trashedPath = trashedPath
        self.originalPath = originalPath
        self.recordedAt = recordedAt
    }
}

public struct TrashLedgerError: ClassifiedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String

    init(_ cls: ErrorClass, _ message: String) {
        self.errorClass = cls
        self.localizedDescription = message
    }
}
