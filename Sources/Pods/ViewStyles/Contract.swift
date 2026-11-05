import Foundation
import HSpaceContracts

// ViewStyles pod's sole public contract surface (Axiom 3): how a folder wants to be shown, and the owner's named styles.
// Values stay raw (Int, String) because the view types live in the app layer. Fields a style does not set are left as they are.

public struct ViewStyle: Sendable, Codable, Equatable {
    public var viewMode: Int?
    public var sortKey: String?
    public var sortAscending: Bool?
    public var includeHidden: Bool?

    public init(viewMode: Int? = nil, sortKey: String? = nil, sortAscending: Bool? = nil, includeHidden: Bool? = nil) {
        self.viewMode = viewMode
        self.sortKey = sortKey
        self.sortAscending = sortAscending
        self.includeHidden = includeHidden
    }
}

public struct SavedViewStyle: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var style: ViewStyle
}

/// A remembered folder
public struct FolderViewRule: Sendable, Codable, Equatable {
    public var style: ViewStyle
    /// Folders below this one follow it too, unless they have a rule of their own
    public var includeSubfolders: Bool

    public init(style: ViewStyle, includeSubfolders: Bool = false) {
        self.style = style
        self.includeSubfolders = includeSubfolders
    }
}

/// The rule in force for a folder
public struct ResolvedViewRule: Sendable, Equatable {
    public let rule: FolderViewRule
    /// The remembered folder it came from
    public let folder: String
    /// False when it is inherited from a parent
    public let isExact: Bool
}

public struct ViewStyleError: ClassifiedError, LocalizedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String
    public var errorDescription: String? { localizedDescription }

    init(_ cls: ErrorClass, _ message: String) {
        self.errorClass = cls
        self.localizedDescription = message
    }
}

public protocol ViewStyleStoring: Sendable {
    /// The rule for a folder: its own, or the nearest parent's that includes subfolders
    func rule(for path: String) -> ResolvedViewRule?
    func folders() -> [String: FolderViewRule]
    func styles() -> [SavedViewStyle]
    func setRule(_ rule: FolderViewRule, for path: String) throws
    func removeRule(for path: String) throws
    /// A blank name, or one already in use whatever its case, is refused
    func saveStyle(named name: String, style: ViewStyle) throws -> SavedViewStyle
    func renameStyle(_ id: UUID, to name: String) throws
    func deleteStyle(_ id: UUID) throws
    /// Hands over, once, a failure at load that no call could throw
    func takeProblem() -> ViewStyleError?
}
