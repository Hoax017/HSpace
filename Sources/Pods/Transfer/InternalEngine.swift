import Foundation
import HSpaceContracts
import Darwin

// Private concern: physical transfer engine: copyfile(3) byte-level progress + cooperative cancellation + same-volume rename fast path

/// Cooperative cancel flag: set by withTaskCancellationHandler, polled by the copyfile callback (thread-safe)
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Progress aggregator: copyfile callbacks fire on the I/O thread; aggregates under a lock and throttles reports (only at >= 512KB or file boundaries)
final class ProgressAggregator: @unchecked Sendable {
    private let lock = NSLock()
    private var filesDone = 0
    private var bytesCompleted: Int64 = 0     // bytes of finished files
    private var currentFileBytes: Int64 = 0   // bytes copied so far of the current file
    private var lastReported: Int64 = 0
    private let report: @Sendable (NodeEvent) -> Void

    init(report: @escaping @Sendable (NodeEvent) -> Void) { self.report = report }

    func currentFile(bytes: Int64, path: String) {
        lock.lock()
        currentFileBytes = bytes
        let total = bytesCompleted + currentFileBytes
        let shouldReport = total - lastReported >= 512 * 1024
        if shouldReport { lastReported = total }
        let files = filesDone
        lock.unlock()
        if shouldReport { report(.progress(filesDone: files, bytesDone: total, currentPath: path)) }
    }

    func fileFinished(bytes: Int64, path: String) {
        lock.lock()
        filesDone += 1
        bytesCompleted += bytes
        currentFileBytes = 0
        lastReported = bytesCompleted
        let files = filesDone, total = bytesCompleted
        lock.unlock()
        report(.progress(filesDone: files, bytesDone: total, currentPath: path))
    }

    /// Same-volume move fast path: the whole tree completes instantly
    func addCompleted(files: Int, bytes: Int64, path: String) {
        lock.lock()
        filesDone += files
        bytesCompleted += bytes
        lastReported = bytesCompleted
        let f = filesDone, total = bytesCompleted
        lock.unlock()
        report(.progress(filesDone: f, bytesDone: total, currentPath: path))
    }

    func snapshotFiles() -> Int { lock.lock(); defer { lock.unlock() }; return filesDone }
    func snapshotBytes() -> Int64 { lock.lock(); defer { lock.unlock() }; return bytesCompleted }
}

/// Dedicated I/O queue: blocking copyfile calls stay off the Swift concurrency cooperative pool
private let ioQueue = DispatchQueue(label: "com.hoax017.hspace.transfer.io", qos: .userInitiated)

extension TransferNode {
    func transferEntry(_ entry: TransferPlan.Entry, mode: TransferPlan.Mode,
                       flag: CancelFlag, progress: ProgressAggregator,
                       entryTotals: ScanTotals) async throws {
        if flag.isSet { throw CancellationError() }
        let fm = FileManager.default

        // Replace never deletes the target first: the new content is built under a temporary sibling name and swapped in,
        // so a failure or cancellation before the swap leaves the old target intact.
        let replacing = entry.replaceExisting && itemExists(entry.destination)

        if mode == .move, sameVolume(entry.source, entry.destination.deletingLastPathComponent()) {
            // Same-volume move = atomic rename, instant
            try moveWithinVolume(from: entry.source, to: entry.destination, replacing: replacing)
            progress.addCompleted(files: entryTotals.files, bytes: entryTotals.bytes,
                                  path: entry.destination.path)
            return
        }

        // Copy (or the copy phase of a cross-volume move)
        if replacing {
            let staged = stagingURL(for: entry.destination)
            do {
                try await copyRecursive(from: entry.source, to: staged, merge: false,
                                        flag: flag, progress: progress)
                if flag.isSet { throw CancellationError() }
                try swapIn(staged, over: entry.destination)
            } catch {
                try discardStaged(staged)
                throw error
            }
            try discardReplaced(staged)
        } else {
            try await copyRecursive(from: entry.source, to: entry.destination,
                                    merge: entry.merge, flag: flag, progress: progress)
        }

        if mode == .move {
            do { try fm.removeItem(at: entry.source) } catch {
                throw TransferError(.external, "Could not remove source after cross-volume move:\(error.localizedDescription)",
                                    path: entry.source.path)
            }
        }
    }

    private func moveWithinVolume(from src: URL, to dst: URL, replacing: Bool) throws {
        guard replacing else {
            do { try FileManager.default.moveItem(at: src, to: dst) } catch {
                throw TransferError(.external, "Move failed:\(error.localizedDescription)", path: src.path)
            }
            return
        }
        let staged = stagingURL(for: dst)
        guard rename(src.path, staged.path) == 0 else {
            throw TransferError(.external, "Move failed:\(String(cString: strerror(errno)))", path: src.path)
        }
        do {
            try swapIn(staged, over: dst)
        } catch {
            guard rename(staged.path, src.path) == 0 else {
                throw TransferError(.external, "Move failed, and the item is now at a temporary name.", path: staged.path)
            }
            throw error
        }
        try discardReplaced(staged)
    }

    private func copyRecursive(from src: URL, to dst: URL, merge: Bool,
                               flag: CancelFlag, progress: ProgressAggregator) async throws {
        if flag.isSet { throw CancellationError() }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: src.path, isDirectory: &isDir) else {
            throw TransferError(.external, "Source not found:\(src.lastPathComponent)", path: src.path)
        }

        if isDir.boolValue, !isPackageTreatedAsFile(src) {
            if !fm.fileExists(atPath: dst.path) {
                do { try fm.createDirectory(at: dst, withIntermediateDirectories: true) } catch {
                    throw TransferError(.external, "Could not create folder:\(error.localizedDescription)", path: dst.path)
                }
            }
            // A listing failure must stop the copy: treated as empty, it would count as copied and a move could delete the source
            let children: [URL]
            do {
                children = try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: [.isDirectoryKey], options: [])
            } catch {
                throw TransferError(.external, "Could not read folder:\(error.localizedDescription)", path: src.path)
            }
            for child in children {
                let childDst = dst.appendingPathComponent(child.lastPathComponent)
                if merge, fm.fileExists(atPath: childDst.path) {
                    var childDstDir: ObjCBool = false
                    var childSrcDir: ObjCBool = false
                    _ = fm.fileExists(atPath: childDst.path, isDirectory: &childDstDir)
                    _ = fm.fileExists(atPath: child.path, isDirectory: &childSrcDir)
                    if !(childDstDir.boolValue && childSrcDir.boolValue) {
                        // Merge semantics: a same-named source file overwrites the target (documented contract promise)
                        try? fm.removeItem(at: childDst)
                    }
                }
                try await copyRecursive(from: child, to: childDst, merge: merge,
                                        flag: flag, progress: progress)
            }
        } else {
            try await copyOneFile(from: src, to: dst, flag: flag, progress: progress)
        }
    }

    /// Single-file copyfile: byte-level progress callback + COPYFILE_QUIT cancellation + partial-file cleanup
    private func copyOneFile(from src: URL, to dst: URL,
                             flag: CancelFlag, progress: ProgressAggregator) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            ioQueue.async {
                do {
                    try copyOneFileSync(from: src, to: dst, flag: flag, progress: progress)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let ka: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let va = try? a.resourceValues(forKeys: ka).volumeIdentifier,
              let vb = try? b.resourceValues(forKeys: ka).volumeIdentifier else { return false }
        return va.isEqual(vb)
    }

    /// Packages such as .app: treating them as one file-level copy unit still works through directory recursion; this only decides progress granularity, and false means recurse
    private func isPackageTreatedAsFile(_ url: URL) -> Bool { false }
}

// MARK: Staged commit

/// `lstat` existence: a dangling symlink is an existing item, unlike `FileManager.fileExists`.
func itemExists(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0
}

/// Hidden sibling of the destination, so the final rename stays on one volume and is atomic.
private func stagingURL(for destination: URL) -> URL {
    destination.deletingLastPathComponent()
        .appendingPathComponent(".hspace-transfer-\(UUID().uuidString)")
}

/// Puts `staged` at `target`. On return `staged` holds the old target, for the caller to discard.
private func swapIn(_ staged: URL, over target: URL) throws {
    if renamex_np(staged.path, target.path, UInt32(RENAME_SWAP)) == 0 { return }
    let swapErrno = errno
    guard swapErrno == ENOTSUP || swapErrno == EINVAL else {
        throw TransferError(.external, "Could not replace destination:\(String(cString: strerror(swapErrno)))",
                            path: target.path)
    }
    // File systems without RENAME_SWAP (exFAT, SMB): same result through three renames, restoring on failure
    let aside = stagingURL(for: target)
    guard rename(target.path, aside.path) == 0 else {
        throw TransferError(.external, "Could not replace destination:\(String(cString: strerror(errno)))",
                            path: target.path)
    }
    guard rename(staged.path, target.path) == 0 else {
        let message = String(cString: strerror(errno))
        guard rename(aside.path, target.path) == 0 else {
            throw TransferError(.external, "Replace failed, and the old item is now at a temporary name:\(message)",
                                path: aside.path)
        }
        throw TransferError(.external, "Could not replace destination:\(message)", path: target.path)
    }
    guard rename(aside.path, staged.path) == 0 else {
        throw TransferError(.external, "Replaced, but the old item remains at a temporary name.", path: aside.path)
    }
}

private func discardReplaced(_ leftover: URL) throws {
    do { try FileManager.default.removeItem(at: leftover) } catch {
        throw TransferError(.external, "Replaced, but the old item could not be removed:\(error.localizedDescription)",
                            path: leftover.path)
    }
}

/// Removes staged output after a failure. If that fails too, the user must learn where the leftover is.
private func discardStaged(_ staged: URL) throws {
    guard itemExists(staged) else { return }
    do { try FileManager.default.removeItem(at: staged) } catch {
        throw TransferError(.external, "Stopped, but partial output could not be removed:\(error.localizedDescription)",
                            path: staged.path)
    }
}

/// copyfile callback context box (passed into the C callback via STATUS_CTX)
private final class CopyContext {
    let flag: CancelFlag
    let progress: ProgressAggregator
    let dstPath: String
    init(flag: CancelFlag, progress: ProgressAggregator, dstPath: String) {
        self.flag = flag; self.progress = progress; self.dstPath = dstPath
    }
}

private func copyOneFileSync(from src: URL, to dst: URL,
                             flag: CancelFlag, progress: ProgressAggregator) throws {
    if flag.isSet { throw CancellationError() }
    // Failure cleanup removes only the partial file created by this run: if the target existed before the copy (external race / clone EEXIST), never delete someone else's file
    let dstPreexisted = FileManager.default.fileExists(atPath: dst.path)
    let state = copyfile_state_alloc()
    defer { copyfile_state_free(state) }

    let box = CopyContext(flag: flag, progress: progress, dstPath: dst.path)
    let ctx = Unmanaged.passRetained(box)
    defer { ctx.release() }

    let callback: copyfile_callback_t = { what, stage, state, _, _, ctxPtr in
        guard let ctxPtr else { return Int32(COPYFILE_CONTINUE) }
        let box = Unmanaged<CopyContext>.fromOpaque(ctxPtr).takeUnretainedValue()
        if box.flag.isSet { return Int32(COPYFILE_QUIT) }
        // Returning CONTINUE at the error stage retries the failed write forever, which hangs on a full disk
        if what == COPYFILE_COPY_DATA, stage == COPYFILE_ERR { return Int32(COPYFILE_QUIT) }
        if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS {
            var copied: off_t = 0
            copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
            box.progress.currentFile(bytes: Int64(copied), path: box.dstPath)
        }
        return Int32(COPYFILE_CONTINUE)
    }

    copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), ctx.toOpaque())
    copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB),
                       unsafeBitCast(callback, to: UnsafeRawPointer.self))

    // COPYFILE_CLONE: instant APFS clone on the same volume; falls back to a real copy across volumes
    let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE | COPYFILE_NOFOLLOW)
    let rc = copyfile(src.path, dst.path, state, flags)

    if rc < 0 {
        let savedErrno = errno   // snapshot first: removeItem clobbers errno
        // Partial-file cleanup: delete only the incomplete target created by this run; leave it if it existed before the copy (avoids deleting someone else's file)
        if !dstPreexisted { try? FileManager.default.removeItem(at: dst) }
        if flag.isSet || savedErrno == ECANCELED { throw CancellationError() }
        let msg = String(cString: strerror(savedErrno))
        throw TransferError(.external, "Copy failed:\(msg)", path: src.path)
    }

    var size: off_t = 0
    copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &size)
    if size == 0 {
        // APFS clone moves no bytes (COPIED=0): account for the target's actual size; progress means logical bytes transferred
        let attrs = try? FileManager.default.attributesOfItem(atPath: dst.path)
        size = off_t((attrs?[.size] as? Int64) ?? 0)
    }
    progress.fileFinished(bytes: Int64(size), path: dst.path)
}
