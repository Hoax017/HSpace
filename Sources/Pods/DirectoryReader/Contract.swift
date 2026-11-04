import Foundation
import HSpaceContracts

// DirectoryReader pod's sole public contract surface (Axiom 3): directory URL → immutable DirectorySnapshot

public struct ReadRequest: Sendable {
    public let directory: URL
    public let includeHidden: Bool
    public let sort: SortSpec

    public init(directory: URL, includeHidden: Bool = false, sort: SortSpec = SortSpec()) {
        self.directory = directory
        self.includeHidden = includeHidden
        self.sort = sort
    }
}

public struct DirectoryReadError: ClassifiedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String
    public let underlying: (any Error)?

    init(_ cls: ErrorClass, _ message: String, underlying: (any Error)? = nil) {
        self.errorClass = cls
        self.localizedDescription = message
        self.underlying = underlying
    }
}

/// Directory reading node: each load gets a monotonically increasing generation;
/// callers compare generations to discard stale results (spec 3.2 generation guard)
public protocol DirectoryReading: Sendable {
    func load(_ request: ReadRequest) async throws -> DirectorySnapshot
}
