import Foundation
import HSpaceContracts

// BookmarkStore pod's sole public contract surface (Axiom 3): sole Commit Owner of custom bookmarks

public struct BookmarkItem: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public var name: String
    /// URL bookmark Data: still resolves after the target is moved or renamed (spec data contract)
    public var bookmarkData: Data

    public init(id: UUID = UUID(), name: String, bookmarkData: Data) {
        self.id = id
        self.name = name
        self.bookmarkData = bookmarkData
    }
}

public struct BookmarkError: ClassifiedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String

    init(_ cls: ErrorClass, _ message: String) {
        self.errorClass = cls
        self.localizedDescription = message
    }
}
