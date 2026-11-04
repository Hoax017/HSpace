import Foundation
import HSpaceContracts

// DirectoryWatch pod's sole public contract surface (Axiom 3): directory URL → change signal stream + suspend/resume/stop handle.
// Each directory change yields one Void signal; callers reload the whole directory on receipt (no incremental diff, DirectoryReader produces a new snapshot).

public struct DirectoryWatchError: ClassifiedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String

    init(_ cls: ErrorClass, _ message: String) {
        self.errorClass = cls
        self.localizedDescription = message
    }
}

/// Watch factory: produces a started DirectoryWatcher handle.
public protocol DirectoryWatching: Sendable {
    /// The returned handle starts watching immediately; hold it to keep watching, releasing it stops automatically (deinit closes the stream).
    func watch(_ path: URL) -> DirectoryWatcher
}
