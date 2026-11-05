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
    ///
    /// Compared on real locations, so a symlink inside the fence cannot carry a path out of it. The source's last
    /// component stays unresolved: deleting a symlink removes the link, never its target.
    /// A path that cannot be resolved is refused.
    public static func isFenced(_ source: URL, by root: URL) -> Bool {
        guard let r = resolved(root.path), let s = resolvedExceptLast(source.path) else { return false }
        guard s != r else { return false }          // the fence itself may not be deleted
        return s.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }

    private static func resolvedExceptLast(_ path: String) -> String? {
        let ns = path as NSString
        let last = ns.lastPathComponent
        // "." and ".." name a directory reached through the path, not an entry of the parent
        if last == "." || last == ".." { return resolved(path) }
        return resolved(ns.deletingLastPathComponent).map { ($0 as NSString).appendingPathComponent(last) }
    }

    /// `realpath`, tolerating components that do not exist yet: the existing start of the path is resolved and the
    /// rest is kept as spelled. Anything else (a dangling link, a loop, no permission) gives nil.
    private static func resolved(_ path: String) -> String? {
        var existing = path
        var missing: [String] = []
        while true {
            if let real = realpath(existing, nil) {
                defer { free(real) }
                let full = missing.reversed().reduce(String(cString: real)) {
                    ($0 as NSString).appendingPathComponent($1)
                }
                return URL(fileURLWithPath: full).standardizedFileURL.path
            }
            var info = stat()
            guard errno == ENOENT || errno == ENOTDIR, lstat(existing, &info) != 0, existing != "/" else {
                return nil
            }
            missing.append((existing as NSString).lastPathComponent)
            existing = (existing as NSString).deletingLastPathComponent
        }
    }
}
