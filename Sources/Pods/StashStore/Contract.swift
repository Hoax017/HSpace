import Foundation
import NSpaceContracts

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

public struct StashError: ClassifiedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String

    init(_ cls: ErrorClass, _ message: String) {
        self.errorClass = cls
        self.localizedDescription = message
    }
}
