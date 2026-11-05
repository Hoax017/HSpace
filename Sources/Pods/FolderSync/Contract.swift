import Foundation
import HSpaceContracts

// FolderSync pod's sole public contract surface (Axiom 3): compares two local folders and carries out the result.
// The pipeline has two doors on purpose. `SyncPlanner` only reads and gives a plan. `SyncExecutor` takes that plan and nothing
// else, so no delete can happen without a plan, and without `confirmedDeletes` the plan's deletes are not carried out.
// Deletes and replaced items go to the Trash. Before each action the disk is checked against the plan, and an item
// that changed since the preview is left alone. If a folder could not be read, the plan holds no delete at all:
// an unreadable folder must never look like an empty one.

public enum SyncDirection: String, Sendable, Codable, CaseIterable {
    case leftToRight, rightToLeft, twoWay
}

public enum SyncComparison: String, Sendable, Codable, CaseIterable {
    /// Same size and modification date within 2 seconds, the precision of some volumes
    case sizeAndDate
    /// Same size and same bytes. Reads both files when the size matches.
    case contents
}

/// What takes part. Excluded items are neither copied nor deleted.
public struct SyncFilter: Sendable, Hashable, Codable {
    /// Globs for files; empty means every file. A pattern with a `/` matches the relative path, others the name.
    public var include: [String]
    /// Globs for files and folders
    public var exclude: [String]
    public var skipHidden: Bool

    public init(include: [String] = [], exclude: [String] = [".DS_Store"], skipHidden: Bool = false) {
        self.include = include
        self.exclude = exclude
        self.skipHidden = skipHidden
    }
}

public struct SyncOptions: Sendable, Hashable, Codable {
    public var direction: SyncDirection
    public var comparison: SyncComparison
    /// Trash what exists only on the receiving side. Ignored for two-way, which cannot tell a deletion from a new file.
    public var deleteExtras: Bool
    public var filter: SyncFilter

    public init(direction: SyncDirection = .leftToRight, comparison: SyncComparison = .sizeAndDate,
                deleteExtras: Bool = false, filter: SyncFilter = SyncFilter()) {
        self.direction = direction
        self.comparison = comparison
        self.deleteExtras = deleteExtras
        self.filter = filter
    }
}

/// Named settings, with or without folders.
public struct SyncPreset: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public var name: String
    public var options: SyncOptions
    public var left: String?
    public var right: String?

    public init(id: UUID = UUID(), name: String, options: SyncOptions, left: String? = nil, right: String? = nil) {
        self.id = id
        self.name = name
        self.options = options
        self.left = left
        self.right = right
    }
}

public enum SyncSkipReason: Sendable, Hashable {
    /// A file on one side and a folder on the other
    case typeMismatch
    /// Two-way: they differ and neither is newer
    case undecided
    /// A folder could not be read, so nothing is deleted
    case scanIncomplete
}

public struct SyncAction: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case createFolder, copy
        /// The old target goes to the Trash, then the source is copied
        case replace
        /// To the Trash
        case delete
        case skip(SyncSkipReason)
    }

    public let relativePath: String
    public let kind: Kind
    public let source: URL?
    public let target: URL
    /// Bytes to copy, or to free for a delete
    public let bytes: Int64
    /// A one-way replace is about to put an older file over a newer one
    public let targetIsNewer: Bool
    /// The action writes to the right folder
    public let towardRight: Bool
    let sourceMark: DiskMark?
    let targetMark: DiskMark?

    public var id: String { "\(towardRight ? ">" : "<")\(relativePath)" }
}

public struct SyncProblem: Sendable, Hashable {
    public let path: String
    public let message: String
}

public struct SyncPlan: Sendable, Equatable {
    public let left: URL
    public let right: URL
    public let options: SyncOptions
    /// In the order they will run: folders, copies, replacements, deletes, then what is skipped
    public let actions: [SyncAction]
    public let identicalCount: Int
    /// Items on the receiving side with no counterpart, kept because deletes are off
    public let extrasKept: Int
    /// Folders that could not be read. Whatever is below them was not compared.
    public let problems: [SyncProblem]
    /// A receiving folder would lose everything: the sign of a wrong folder or an unmounted volume
    public let wouldEmptyReceiver: Bool

    public func count(_ kind: SyncAction.Kind) -> Int { actions.filter { $0.kind == kind }.count }
    public var deletes: [SyncAction] { actions.filter { $0.kind == .delete } }
    public var skipped: [SyncAction] {
        actions.filter {
            if case .skip = $0.kind { return true }
            return false
        }
    }
    public var hasWork: Bool { actions.count > skipped.count }
    public var bytesToCopy: Int64 {
        actions.filter { $0.kind == .copy || $0.kind == .replace }.reduce(0) { $0 + $1.bytes }
    }
}

public struct SyncError: ClassifiedError, LocalizedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String
    public var errorDescription: String? { localizedDescription }

    init(_ cls: ErrorClass, _ message: String) {
        self.errorClass = cls
        self.localizedDescription = message
    }
}

/// How the pod reaches the file system: through kernel operations in the app, directly in nothing (BG-1).
/// A closure throws on failure and `CancellationError` on cancel.
public struct SyncDriver: Sendable {
    public let copy: @Sendable (_ sources: [URL], _ folder: URL) async throws -> Void
    public let trash: @Sendable (_ items: [URL]) async throws -> Void
    public let makeFolder: @Sendable (_ name: String, _ parent: URL) async throws -> Void

    public init(copy: @escaping @Sendable ([URL], URL) async throws -> Void,
                trash: @escaping @Sendable ([URL]) async throws -> Void,
                makeFolder: @escaping @Sendable (String, URL) async throws -> Void) {
        self.copy = copy
        self.trash = trash
        self.makeFolder = makeFolder
    }
}

public enum SyncMode: Sendable, Equatable {
    /// Checks every action against the disk and writes nothing
    case dryRun
    /// `confirmedDeletes` is the user's yes to the plan's deletes. Without it they are left out.
    case apply(confirmedDeletes: Bool)
}

public struct SyncReport: Sendable, Equatable {
    public var isDryRun = false
    public var foldersCreated = 0
    public var copied = 0
    public var replaced = 0
    public var deleted = 0
    public var bytesCopied: Int64 = 0
    /// Left alone: changed since the preview
    public var changedSincePreview: [String] = []
    public var failures: [SyncProblem] = []
    /// Deletes in the plan that were left out for want of a confirmation
    public var unconfirmedDeletes = 0
    public var wasCancelled = false
    /// A failure stopped the run. Nothing after it ran, deletes included.
    public var stoppedEarly = false

    public var isClean: Bool { failures.isEmpty && !wasCancelled && changedSincePreview.isEmpty }
}
