import Foundation

// MARK: - Directory projection (read-only projection of the file system, BG-5)

public struct FileItem: Sendable, Hashable {
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isPackage: Bool
    public let isSymlink: Bool
    public let isHidden: Bool
    /// File size in bytes; nil for directories (backfilled on demand by the FolderSize pod)
    public let size: Int64?
    public let modified: Date?
    public let created: Date?
    /// Date added to the containing directory (for column filters)
    public let added: Date?
    /// UTType.identifier; the kind display string is cached and derived from it
    public let contentTypeID: String?

    public init(url: URL, name: String, isDirectory: Bool, isPackage: Bool,
                isSymlink: Bool, isHidden: Bool, size: Int64?,
                modified: Date?, created: Date?, added: Date? = nil, contentTypeID: String?) {
        self.url = url; self.name = name
        self.isDirectory = isDirectory; self.isPackage = isPackage
        self.isSymlink = isSymlink; self.isHidden = isHidden
        self.size = size; self.modified = modified; self.created = created
        self.added = added
        self.contentTypeID = contentTypeID
    }
}

public struct DirectorySnapshot: Sendable {
    public let directory: URL
    /// Generation token: stale slow-load results must not overwrite a newer navigation (spec 3.2)
    public let generation: UInt64
    public let items: [FileItem]

    public init(directory: URL, generation: UInt64, items: [FileItem]) {
        self.directory = directory; self.generation = generation; self.items = items
    }
}

public struct SortSpec: Sendable, Hashable, Codable {
    public enum Key: String, Sendable, Codable, CaseIterable { case name, dateModified, size, kind, created, added }
    public var key: Key
    public var ascending: Bool
    public var foldersFirst: Bool

    public init(key: Key = .name, ascending: Bool = true, foldersFirst: Bool = true) {
        self.key = key; self.ascending = ascending; self.foldersFirst = foldersFirst
    }
}

// MARK: - Three error classes (every pod Error must fall into one, BG-4 / P6.4)

public enum ErrorClass: Sendable, Equatable {
    /// Internal logic error, do not retry
    case logic
    /// System hiccup, retryable
    case transient
    /// External dependency problem such as permissions or an unavailable volume; tell the user
    case external
}

public protocol ClassifiedError: Error, Sendable {
    var errorClass: ErrorClass { get }
    var localizedDescription: String { get }
}

// MARK: - Operation contract (Typed Command from presentation layer → kernel, BG-1)

public struct OperationSpec: Sendable {
    public enum Kind: String, Sendable {
        case copy, move, trash, duplicate, newFolder, newFile, rename
        /// **Permanent deletion (irreversible)**: Eraser pod. Must carry destination as the fence root,
        /// and every source must fall inside the fence, otherwise the whole batch is refused (blast radius written into the contract, not a comment)
        case delete
        /// Compress into an archive (ArchiveEngine)
        case compress
        /// Extract from an archive (ArchiveEngine)
        case extract
    }
    public let kind: Kind
    public let sources: [URL]
    public let destination: URL?
    /// For rename / newFolder / newFile; optional for compress: archive base name (no extension, nil = node derives it from the sources)
    public let newName: String?
    /// Options specific to compress / extract (always nil for other kinds, backward compatible)
    public let archiveOptions: ArchiveOptions?
    /// `newFile` only: initial file contents. nil = create an empty file (existing behaviour unchanged).
    /// Added for "⌘V pastes clipboard contents as a new file": the presentation layer may not write to disk itself (BG-1),
    /// so contents can only travel with the Command to the kernel and be landed by the pod node.
    public let contents: Data?

    public init(kind: Kind, sources: [URL], destination: URL? = nil, newName: String? = nil,
                archiveOptions: ArchiveOptions? = nil, contents: Data? = nil) {
        self.kind = kind; self.sources = sources
        self.destination = destination; self.newName = newName
        self.archiveOptions = archiveOptions
        self.contents = contents
    }
}

/// Archive options (for compress / extract; Sendable value type)
public struct ArchiveOptions: Sendable, Equatable {
    /// Archive format: "zip" / "tar.gz" (for compress; extract dispatches by the archive's extension and ignores this field)
    public let format: String
    /// Encryption password; nil / empty = no encryption. zip uses ZipCrypto (weak encryption, see the Contract comment)
    public let password: String?
    /// Whether compress keeps the originals (false = trash/delete the sources after packing; v1 always keeps them, the UI decides)
    public let keepOriginal: Bool
    /// extract target directory; nil = extract next to the archive
    public let extractInto: URL?
    /// Whether extract ensures a "wrapper folder" (more than one top-level entry → create a same-named folder first; a single entry skips it)
    public let createWrapper: Bool

    public init(format: String = "zip", password: String? = nil, keepOriginal: Bool = true,
                extractInto: URL? = nil, createWrapper: Bool = true) {
        self.format = format
        self.password = password
        self.keepOriginal = keepOriginal
        self.extractInto = extractInto
        self.createWrapper = createWrapper
    }
}

/// Operation Run state machine (spec 3.1; committed only by OperationKernel)
public enum RunState: Sendable, Equatable {
    case pending
    case scanning
    case awaitingConflict
    case running
    case completed
    case cancelled
    case failed(message: String, errorClass: ErrorClass)

    public var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .failed: return true
        default: return false
        }
    }

    public static func == (lhs: RunState, rhs: RunState) -> Bool {
        switch (lhs, rhs) {
        case (.pending, .pending), (.scanning, .scanning), (.awaitingConflict, .awaitingConflict),
             (.running, .running), (.completed, .completed), (.cancelled, .cancelled):
            return true
        case let (.failed(m1, _), .failed(m2, _)):
            return m1 == m2
        default:
            return false
        }
    }
}

/// Read-only projection from kernel → progress window (pushed via AsyncStream)
public struct OperationProjection: Sendable {
    public let id: UUID
    public let kind: OperationSpec.Kind
    public let state: RunState
    public let filesDone: Int
    public let filesTotal: Int
    public let bytesDone: Int64
    public let bytesTotal: Int64
    public let currentPath: String?

    public init(id: UUID, kind: OperationSpec.Kind, state: RunState,
                filesDone: Int, filesTotal: Int, bytesDone: Int64, bytesTotal: Int64,
                currentPath: String?) {
        self.id = id; self.kind = kind; self.state = state
        self.filesDone = filesDone; self.filesTotal = filesTotal
        self.bytesDone = bytesDone; self.bytesTotal = bytesTotal
        self.currentPath = currentPath
    }
}

// MARK: - Conflict resolution

public struct FileConflict: Sendable, Hashable {
    public let source: URL
    public let existing: URL
    public let bothDirectories: Bool

    public init(source: URL, existing: URL, bothDirectories: Bool) {
        self.source = source; self.existing = existing; self.bothDirectories = bothDirectories
    }
}

public enum ConflictDecision: Sendable {
    case replace, skip, keepBoth, mergeFolders
    /// Rename and coexist: newName is the new file name (with extension) inside the destination directory. The UI guarantees it is non-empty.
    case rename(String)
}

/// One Trash pair: original location → Trash location (lets undo move trashed back to original)
public struct TrashedItem: Sendable, Hashable {
    public let original: URL
    public let trashed: URL
    public init(original: URL, trashed: URL) {
        self.original = original; self.trashed = trashed
    }
}

/// Proof of an operation's real outcome (Proof Owner artifact)
/// Single-item failure: a **partially successful** operation uses this to report which item failed and why.
///
/// Why it exists (an existing defect caught by adversarial review, v0.19.18): nodes used to `throw` at the first error,
/// and whatever had really landed was lost with the throw: the kernel stores receipts only on the success path, so the UI got nil
/// and neither registered undo, showed a toast, nor reported an error. The user's files really went to Trash with no undo and no notice.
/// "Partial success" is a real outcome, not an exception; it must be expressible.
public struct OperationFailure: Sendable {
    public let url: URL
    public let errorClass: ErrorClass
    public let message: String

    public init(url: URL, errorClass: ErrorClass, message: String) {
        self.url = url; self.errorClass = errorClass; self.message = message
    }
}

public struct OperationReceipt: Sendable {
    public let id: UUID
    public let filesDone: Int
    public let bytesDone: Int64
    public let duration: TimeInterval
    /// Operations producing new entries (newFolder / newFile etc.) return result URLs (the UI selects them and enters rename)
    public let createdURLs: [URL]
    /// trash returns original URL → Trash URL pairs (the UI registers undo with them)
    public let trashedItems: [TrashedItem]
    /// Per-item failure list. Non-empty = partial success: the kernel marks the state .failed (the state tells the truth),
    /// but **the receipt is stored anyway**, so the UI can register undo for what landed and report truthfully.
    public let failures: [OperationFailure]

    public init(id: UUID, filesDone: Int, bytesDone: Int64, duration: TimeInterval,
                createdURLs: [URL] = [], trashedItems: [TrashedItem] = [],
                failures: [OperationFailure] = []) {
        self.id = id; self.filesDone = filesDone; self.bytesDone = bytesDone; self.duration = duration
        self.createdURLs = createdURLs; self.trashedItems = trashedItems
        self.failures = failures
    }
}

// MARK: - Node contracts (pods depend only on this vocabulary, not on the kernel implementation, BG-4/BG-6)

/// Events a node reports to the kernel during execution (progress aspect; telemetry failure must not hurt the main path, BG-7)
public enum NodeEvent: Sendable {
    case scanTotals(files: Int, bytes: Int64)
    case progress(filesDone: Int, bytesDone: Int64, currentPath: String?)
}

/// Context the kernel injects into nodes: report progress, request conflict decisions
public struct NodeContext: Sendable {
    public let operationID: UUID
    public let report: @Sendable (NodeEvent) -> Void
    /// Returning nil = the user cancelled the whole operation
    public let resolveConflicts: @Sendable ([FileConflict]) async -> [URL: ConflictDecision]?

    public init(operationID: UUID,
                report: @escaping @Sendable (NodeEvent) -> Void,
                resolveConflicts: @escaping @Sendable ([FileConflict]) async -> [URL: ConflictDecision]?) {
        self.operationID = operationID
        self.report = report
        self.resolveConflicts = resolveConflicts
    }
}

/// Unified contract for semantic atomic nodes: a single atomic state transition, strongly typed in and out (P6)
public protocol OperationNode: Sendable {
    func execute(_ spec: OperationSpec, context: NodeContext) async throws -> OperationReceipt
}

/// Conflict resolution delegate (implemented by the presentation layer as the conflict panel; the kernel does not know the UI exists)
public protocol ConflictArbiter: Sendable {
    /// Returning nil = the user cancelled the operation in the panel
    func arbitrate(operation id: UUID, conflicts: [FileConflict]) async -> [URL: ConflictDecision]?
}
