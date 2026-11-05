import Foundation
import HSpaceContracts

// FileInspector pod's sole public contract surface (Axiom 3): what is known about one item, read-only.
// Facts come from file headers, never from decoding contents, so inspecting a huge file costs the same as a small one.

public struct InspectorError: ClassifiedError, LocalizedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String
    public var errorDescription: String? { localizedDescription }

    init(_ cls: ErrorClass, _ message: String) {
        self.errorClass = cls
        self.localizedDescription = message
    }
}

public struct ImageFacts: Sendable, Equatable {
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let dpi: Double?
    public let colorModel: String?
    public let hasAlpha: Bool?
}

public struct MediaFacts: Sendable, Equatable {
    /// Seconds. nil when the file gives none.
    public let duration: Double?
    /// Pixels of the first video track. nil for audio.
    public let videoWidth: Int?
    public let videoHeight: Int?
}

public struct InspectorFacts: Sendable, Equatable {
    public let url: URL
    public let name: String
    /// UTType.identifier
    public let typeID: String?
    public let isDirectory: Bool
    public let isPackage: Bool
    public let isSymlink: Bool
    /// What a symlink says, as written
    public let linkTarget: String?
    public let linkIsBroken: Bool
    /// nil for a folder
    public let logicalSize: Int64?
    public let allocatedSize: Int64?
    public let created: Date?
    public let modified: Date?
    public let accessed: Date?
    public let added: Date?
    /// The nine rwx bits plus setuid, setgid and sticky
    public let permissions: UInt16?
    public let owner: String?
    public let group: String?
    public let isLocked: Bool
    public let isHidden: Bool
    /// Direct children of a folder. nil for anything else, or when the folder cannot be read.
    public let childCount: Int?
    public let image: ImageFacts?
    public let media: MediaFacts?
    public let pageCount: Int?
}

public enum Permissions {
    /// "rwxr-xr--", with s and t where those bits are set
    public static func symbolic(_ mode: UInt16) -> String {
        func triad(_ shift: UInt16, special: Bool, on: Character, off: Character) -> String {
            let bits = (mode >> shift) & 0o7
            let last: Character = bits & 1 != 0 ? (special ? on : "x") : (special ? off : "-")
            return (bits & 4 != 0 ? "r" : "-") + (bits & 2 != 0 ? "w" : "-") + String(last)
        }
        return triad(6, special: mode & 0o4000 != 0, on: "s", off: "S")
            + triad(3, special: mode & 0o2000 != 0, on: "s", off: "S")
            + triad(0, special: mode & 0o1000 != 0, on: "t", off: "T")
    }

    /// "755", or "4755" when a special bit is set
    public static func octal(_ mode: UInt16) -> String {
        String(mode & 0o7777, radix: 8)
    }
}

/// What several items add up to. Sizes of folders are not in a listing and arrive apart, through `adding`.
public struct SelectionTally: Sendable, Equatable {
    public let count: Int
    public let folders: Int
    public let bytes: Int64
    /// The one type all items share. nil when they differ.
    public let sharedTypeID: String?
    /// Folder sizes still missing, or that could not be read: `bytes` is then a lower bound
    public let isPartial: Bool

    public init(_ items: [FileItem]) {
        count = items.count
        folders = items.filter { $0.isDirectory && !$0.isPackage }.count
        bytes = items.reduce(0) { $0 + ($1.size ?? 0) }
        let types = Set(items.map(\.contentTypeID))
        sharedTypeID = types.count == 1 ? types.first ?? nil : nil
        isPartial = items.contains { $0.size == nil }
    }

    private init(count: Int, folders: Int, bytes: Int64, sharedTypeID: String?, isPartial: Bool) {
        self.count = count
        self.folders = folders
        self.bytes = bytes
        self.sharedTypeID = sharedTypeID
        self.isPartial = isPartial
    }

    /// The tally once folder sizes are known. `complete` = every folder gave its size.
    public func adding(folderBytes: Int64, complete: Bool) -> SelectionTally {
        SelectionTally(count: count, folders: folders, bytes: bytes + folderBytes,
                       sharedTypeID: sharedTypeID, isPartial: !complete)
    }
}

public protocol FileInspecting: Sendable {
    /// Reads the facts of one item. A symlink is described itself, not what it points to.
    /// Runs off the caller's actor. Parts that cannot be read stay nil: only a missing or unreachable item throws `InspectorError`.
    /// Cancellation throws CancellationError.
    func inspect(_ url: URL) async throws -> InspectorFacts
}
