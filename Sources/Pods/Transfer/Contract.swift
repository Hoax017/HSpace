import Foundation
import HSpaceContracts

// Transfer pod's sole public contract surface (Axiom 3):
// Composite Node: copy / move / duplicate (internal micro-steps: pre-scan → conflict resolution → per-file transfer)
// Node boundaries follow irreversible side effects: one operation = one atomic commit unit

public struct TransferError: ClassifiedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String
    public let path: String?

    init(_ cls: ErrorClass, _ message: String, path: String? = nil) {
        self.errorClass = cls
        self.localizedDescription = message
        self.path = path
    }
}

/// "Keep both" naming rule (pure logic, black-box unit-testable):
/// file.txt → file 2.txt → file 3.txt… (always adds a suffix, never returns the original name: keepBoth keeps the existing item and adds a copy)
public func keepBothName(for source: URL, in destinationDir: URL,
                         existsCheck: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> String {
    let base = source.deletingPathExtension().lastPathComponent
    let ext = source.pathExtension
    var n = 2
    while true {
        let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
        if !existsCheck(destinationDir.appendingPathComponent(candidate)) { return candidate }
        n += 1
    }
}

/// Rename fallback naming: returns the desired name if it is free, otherwise desired → "desired 2" → … (never overwrites).
/// Unlike keepBothName, rename may land on desired itself (explicit user intent); keepBoth always adds a copy.
public func uniqueName(base: String, ext: String, in destinationDir: URL,
                       existsCheck: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> String {
    let firstName = ext.isEmpty ? base : "\(base).\(ext)"
    if !existsCheck(destinationDir.appendingPathComponent(firstName)) { return firstName }
    var n = 2
    while true {
        let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
        if !existsCheck(destinationDir.appendingPathComponent(candidate)) { return candidate }
        n += 1
    }
}

/// Merge semantics (documented promise): mergeFolders recursively merges directory contents. A name clash between two files replaces the target file;
/// a clash between a file and a folder deletes neither, and the incoming item gets a new name. Symlinks count as files and are never followed.
public enum TransferMergePolicy {
    public static let documentation = "merge = recursive union; a same-named source file replaces a target file; same-named subfolders recurse; a file and a folder of the same name are both kept"
}
