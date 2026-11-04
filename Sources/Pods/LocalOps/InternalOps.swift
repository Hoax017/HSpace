import Foundation
import NSpaceContracts

// Private concern: physical implementation of the four local operations (real FileManager side effects; errors classified on the spot into the three classes)

extension LocalOpsNode {

    // MARK: Rename (same-directory moveItem; on FG-6 failure the UI side rolls back atomically)

    func renameEntry(_ spec: OperationSpec, context: NodeContext, started: Date) throws -> OperationReceipt {
        let fm = FileManager.default
        guard spec.sources.count == 1, let src = spec.sources.first else {
            throw LocalOpsError(.logic, "rename requires exactly one source")
        }
        guard let newName = spec.newName, !newName.isEmpty else {
            throw LocalOpsError(.logic, "rename requires a non-empty new name")
        }
        guard !newName.contains("/"), newName != ".", newName != ".." else {
            throw LocalOpsError(.logic, "Invalid file name:\(newName)")
        }
        guard fm.fileExists(atPath: src.path) else {
            throw LocalOpsError(.external, "Source not found:\(src.lastPathComponent)", path: src.path)
        }
        let dst = src.deletingLastPathComponent().appendingPathComponent(newName)
        // Same name (case-only changes excepted) is a no-op, avoiding a moveItem self-overwrite error
        if dst.path == src.path {
            return OperationReceipt(id: context.operationID, filesDone: 0, bytesDone: 0,
                                    duration: Date().timeIntervalSince(started), createdURLs: [src])
        }
        if fm.fileExists(atPath: dst.path) {
            throw LocalOpsError(.external, "An item with this name already exists:\(newName)", path: dst.path)
        }
        context.report(.scanTotals(files: 1, bytes: 0))
        do {
            try fm.moveItem(at: src, to: dst)
        } catch {
            throw LocalOpsError(.external, "Rename failed:\(error.localizedDescription)", path: src.path)
        }
        context.report(.progress(filesDone: 1, bytesDone: 0, currentPath: dst.path))
        return OperationReceipt(id: context.operationID, filesDone: 1, bytesDone: 0,
                                duration: Date().timeIntervalSince(started), createdURLs: [dst])
    }

    // MARK: New folder / new file (duplicates get a sequence number; the result URL is returned for select + rename)

    func createEntry(_ spec: OperationSpec, context: NodeContext, isDirectory: Bool,
                     defaultBase: String, started: Date) throws -> OperationReceipt {
        let fm = FileManager.default
        guard let dir = spec.destination else {
            throw LocalOpsError(.logic, "creating an item requires a destination directory")
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw LocalOpsError(.external, "Destination folder unavailable:\(dir.lastPathComponent)", path: dir.path)
        }
        let raw = (spec.newName?.isEmpty == false) ? spec.newName! : defaultBase
        // With contents (⌘V pastes as a new file) the name carries an extension, so it must be split before deduping:
        // otherwise uniqueName(ext: "") yields "Pasted Text.txt 2" instead of "Pasted Text 2.txt".
        // Without contents the naming is entirely unchanged (existing newFile assertions are unaffected).
        let name: String
        if spec.contents != nil {
            let ext = (raw as NSString).pathExtension
            let stem = (raw as NSString).deletingPathExtension
            name = uniqueName(base: stem.isEmpty ? defaultBase : stem, ext: ext, in: dir)
        } else {
            name = uniqueName(base: raw, ext: "", in: dir)
        }
        let url = dir.appendingPathComponent(name)
        let bytes = Int64(spec.contents?.count ?? 0)
        context.report(.scanTotals(files: 1, bytes: bytes))
        do {
            if isDirectory {
                try fm.createDirectory(at: url, withIntermediateDirectories: false)
            } else {
                guard fm.createFile(atPath: url.path, contents: spec.contents ?? Data()) else {
                    throw LocalOpsError(.external, "Could not create file:\(name)", path: url.path)
                }
            }
        } catch let e as LocalOpsError {
            throw e
        } catch {
            throw LocalOpsError(.external, "Could not create item:\(error.localizedDescription)", path: url.path)
        }
        context.report(.progress(filesDone: 1, bytesDone: bytes, currentPath: url.path))
        return OperationReceipt(id: context.operationID, filesDone: 1, bytesDone: bytes,
                                duration: Date().timeIntervalSince(started), createdURLs: [url])
    }

    // MARK: Move to Trash (records original URL → Trash URL pairs for undo)

    func trashEntries(_ spec: OperationSpec, context: NodeContext, started: Date) throws -> OperationReceipt {
        let fm = FileManager.default
        guard !spec.sources.isEmpty else {
            throw LocalOpsError(.logic, "trash requires at least one source")
        }
        context.report(.scanTotals(files: spec.sources.count, bytes: 0))
        var pairs: [TrashedItem] = []
        var failures: [OperationFailure] = []
        var done = 0
        // Per-item fault tolerance; do not stop at the first error.
        // The old version threw on any item failure, and items that had **really landed** were lost with the throw: the kernel stores receipts only on the success path,
        // so the UI got nil and neither registered undo, showed a toast, nor reported an error: the user's files really went to Trash
        // with no undo and no notice. This path got easier to hit once Trash became browsable (items inside Trash cannot be moved there).
        for src in spec.sources {
            guard fm.fileExists(atPath: src.path) else {
                failures.append(OperationFailure(url: src, errorClass: .external,
                                                 message: "Source not found:\(src.lastPathComponent)"))
                continue
            }
            var resulting: NSURL?
            do {
                try fm.trashItem(at: src, resultingItemURL: &resulting)
            } catch {
                failures.append(OperationFailure(url: src, errorClass: .external,
                                                 message: "Could not move to Trash:\(error.localizedDescription)"))
                continue
            }
            // If the Trash location is unknown, fall back to the original name (undo can still try the original path)
            let trashed = (resulting as URL?) ?? src
            pairs.append(TrashedItem(original: src, trashed: trashed))
            done += 1
            context.report(.progress(filesDone: done, bytesDone: 0, currentPath: src.path))
        }
        // Nothing done at all = a real failure; it must not be dressed up as "partial success"
        if pairs.isEmpty, let first = failures.first {
            throw LocalOpsError(first.errorClass, first.message, path: first.url.path)
        }
        return OperationReceipt(id: context.operationID, filesDone: done, bytesDone: 0,
                                duration: Date().timeIntervalSince(started),
                                trashedItems: pairs, failures: failures)
    }
}
