import Foundation
import HSpaceContracts

// StashStore pod's sole public contract surface (Axiom 3): sole Commit Owner of stash shelf contents

public struct StashItem: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    /// URL bookmark Data: still resolves after the target is moved or renamed (spec data contract)
    public var bookmarkData: Data

    public init(id: UUID = UUID(), bookmarkData: Data) {
        self.id = id
        self.bookmarkData = bookmarkData
    }
}

public struct StashError: ClassifiedError, LocalizedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String
    /// What `localizedDescription` gives on `any Error`, which is how the app receives it
    public var errorDescription: String? { localizedDescription }

    init(_ cls: ErrorClass, _ message: String) {
        self.errorClass = cls
        self.localizedDescription = message
    }
}
