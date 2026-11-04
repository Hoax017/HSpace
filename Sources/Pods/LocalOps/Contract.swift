import Foundation
import HSpaceContracts

// LocalOps pod's sole public contract surface (Axiom 3):
// Directory-level local atomic operations: rename / new folder / new file / move to Trash
// Node boundaries follow irreversible side effects: each operation = one atomic commit unit; complements Transfer (cross-directory transfer) without overlap

public struct LocalOpsError: ClassifiedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String
    public let path: String?

    init(_ cls: ErrorClass, _ message: String, path: String? = nil) {
        self.errorClass = cls
        self.localizedDescription = message
        self.path = path
    }
}

/// Default base name for new entries (used when the UI creates without a name; duplicates get " 2"/" 3"… appended).
/// Pure logic, black-box unit-testable: finds the first non-conflicting candidate name in the directory.
public func uniqueName(base: String, ext: String, in directory: URL,
                       existsCheck: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> String {
    func compose(_ n: Int) -> String {
        let stem = n <= 1 ? base : "\(base) \(n)"
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }
    var n = 1
    while existsCheck(directory.appendingPathComponent(compose(n))) { n += 1 }
    return compose(n)
}
