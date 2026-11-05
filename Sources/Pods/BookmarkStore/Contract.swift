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

public struct BookmarkError: ClassifiedError, LocalizedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String
    /// What `localizedDescription` gives on `any Error`, which is how the app receives it
    public var errorDescription: String? { localizedDescription }

    init(_ cls: ErrorClass, _ message: String) {
        self.errorClass = cls
        self.localizedDescription = message
    }
}
