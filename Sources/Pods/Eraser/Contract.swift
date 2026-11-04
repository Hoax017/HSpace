import Foundation
import HSpaceContracts

// Eraser pod's sole public contract surface (Axiom 3): **irreversible** permanent deletion.
//
// Why this is separate instead of living in LocalOps: LocalOps is a mature node already running (rename/newFolder/
// newFile/trash); adding a "gone for good" branch to its switch trades convenience today for fear of touching it tomorrow.
// The blast radius of permanent deletion is on another scale from other local operations; it deserves its own boundary, guards and proofs.

public struct EraserError: ClassifiedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String

    init(_ cls: ErrorClass, _ message: String) {
        self.errorClass = cls
        self.localizedDescription = message
    }
}

public enum EraserLimits {
    /// Blast-radius guard: `.delete` must carry `destination` as the **fence root**, and every source
    /// must fall inside it, otherwise the whole batch is refused.
    ///
    /// This is not an imaginary gate: permanent deletion is the only irreversible operation in this repo, and one mistyped path means user data is gone.
    /// Making callers declare "I only delete within this scope" writes the scope into the contract instead of a comment.
    /// The node has no concept of "Trash": the caller supplies the fence, and the pod holds zero business knowledge.
    public static func isFenced(_ source: URL, by root: URL) -> Bool {
        let r = root.standardizedFileURL.path
        let s = source.standardizedFileURL.path
        guard s != r else { return false }          // the fence itself may not be deleted
        return s.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }
}
