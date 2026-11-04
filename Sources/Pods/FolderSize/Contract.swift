import Foundation
import HSpaceContracts

// FolderSize pod's sole public contract surface (Axiom 3): directory URL → recursive allocated bytes (backfills FileItem.size on demand).

public struct FolderSizeError: ClassifiedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String
    public let underlying: (any Error)?

    init(_ cls: ErrorClass, _ message: String, underlying: (any Error)? = nil) {
        self.errorClass = cls
        self.localizedDescription = message
        self.underlying = underlying
    }
}

public protocol FolderSizing: Sendable {
    /// Recursively sums the allocated bytes of all regular files under url (prefers totalFileAllocatedSize, falls back to fileSize).
    /// Cache hits return directly; deep enumeration concurrency is bounded; cancellation is cooperative via Task.isCancelled and throws CancellationError.
    func size(of url: URL) async throws -> Int64
    /// Invalidates a path's cache (call after its contents change; the next size call recomputes).
    func invalidate(_ url: URL) async
}
