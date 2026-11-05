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

        // Replace never deletes the target first, and nothing appears under the final name until it is complete:
        // the new content is built under a temporary sibling name and renamed in, so a failure or cancellation leaves no partial output.
        let replacing = entry.replaceExisting && itemExists(entry.destination)

        // A merge cannot be one rename: it goes through the copy path, where clones keep it fast on the same volume
        if mode == .move, !entry.merge, sameVolume(entry.source, entry.destination.deletingLastPathComponent()) {
            // Same-volume move = atomic rename, instant
            try moveWithinVolume(from: entry.source, to: entry.destination, replacing: replacing)
            progress.addCompleted(files: entryTotals.files, bytes: entryTotals.bytes,
                                  path: entry.destination.path)
            return
        }

        // Copy (or the copy phase of a move across volumes or into a merge, which records what it copied for verification)
        let run = CopyRun(flag: flag, progress: progress, manifest: mode == .move ? CopyManifest() : nil)
        if entry.merge {
            // A merge writes into the existing folder, so it cannot be staged: it undoes what it added instead
            do {
                try await copyRecursive(from: entry.source, to: entry.destination, merge: true, run: run)
                try await verifyCopy(of: entry.source, run: run)
                try run.finishFolders()
            } catch {
                try run.removeCreated()
                throw error
            }
        } else {
            let staged = stagingURL(for: entry.destination)
            do {
                try await copyRecursive(from: entry.source, to: staged, merge: false, run: run)
                try await verifyCopy(of: entry.source, run: run)
                if flag.isSet { throw CancellationError() }
                try run.finishFolders()
                if replacing {
                    try swapIn(staged, over: entry.destination)
                } else {
                    try renameExclusive(staged, to: entry.destination)
                }
            } catch {
                try discardStaged(staged)
                throw error
            }
            if replacing { try discardReplaced(staged) }
        }

        if mode == .move {
            do { try fm.removeItem(at: entry.source) } catch {
                throw TransferError(.external, "Could not remove source after move:\(error.localizedDescription)",
                                    path: entry.source.path)
            }
        }
    }

    private func moveWithinVolume(from src: URL, to dst: URL, replacing: Bool) throws {
        guard replacing else {
            try renameExclusive(src, to: dst)
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

    private func copyRecursive(from src: URL, to dst: URL, merge: Bool, run: CopyRun) async throws {
        if run.flag.isSet { throw CancellationError() }
        let fm = FileManager.default
        // lstat view: a symlink is copied as a link and never followed, so link cycles and dangling links need no special case
        guard itemExists(src) else {
            throw TransferError(.external, "Source not found:\(src.lastPathComponent)", path: src.path)
        }

        if isRealDirectory(src), !isPackageTreatedAsFile(src) {
            // Only a merge may enter an existing folder: outside one, it appeared after the conflict check and is not ours
            if !merge || !itemExists(dst) {
                do { try fm.createDirectory(at: dst, withIntermediateDirectories: false) } catch {
                    throw TransferError(.external, "Could not create folder:\(error.localizedDescription)", path: dst.path)
                }
                run.noteFolder(src, dst)
            }
            // A listing failure must stop the copy: treated as empty, it would count as copied and a move could delete the source
            let children: [URL]
            do {
                children = try fm.contentsOfDirectory(atPath: src.path).map { src.appendingPathComponent($0) }
            } catch {
                throw TransferError(.external, "Could not read folder:\(error.localizedDescription)", path: src.path)
            }
            run.manifest?.record(src, dst)
            for child in children {
                var childDst = dst.appendingPathComponent(child.lastPathComponent)
                if merge {
                    let sourceIsFolder = isRealDirectory(child)
                    if !itemExists(childDst) {
                        run.noteCreated(childDst)
                    } else if !sourceIsFolder, !isRealDirectory(childDst) {
                        // Merge semantics: a same-named source file replaces the target file (documented contract promise)
                        try await replaceFile(child, over: childDst, run: run)
                        continue
                    } else if sourceIsFolder != isRealDirectory(childDst) {
                        // A file and a folder share the name: neither may be deleted for the other, so the incoming item gets a new name
                        childDst = dst.appendingPathComponent(keepBothName(for: child, in: dst, existsCheck: itemExists))
                        run.noteCreated(childDst)
                    }
                }
                try await copyRecursive(from: child, to: childDst, merge: merge, run: run)
            }
        } else {
            try await copyOneFile(from: src, to: dst, flag: run.flag, progress: run.progress)
            run.manifest?.record(src, dst)
        }
    }

    private func replaceFile(_ src: URL, over target: URL, run: CopyRun) async throws {
        let staged = stagingURL(for: target)
        do {
            try await copyOneFile(from: src, to: staged, flag: run.flag, progress: run.progress)
            try swapIn(staged, over: target)
        } catch {
            try discardStaged(staged)
            throw error
        }
        try discardReplaced(staged)
        run.manifest?.record(src, target)
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

    /// Only moves record a manifest: a copy keeps its source, so it has nothing to verify before deleting
    private func verifyCopy(of src: URL, run: CopyRun) async throws {
        guard let manifest = run.manifest else { return }
        let flag = run.flag
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            ioQueue.async {
                do {
                    try verifyItem(src, against: manifest, flag: flag)
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

/// State of one entry's copy.
private final class CopyRun: @unchecked Sendable {
    let flag: CancelFlag
    let progress: ProgressAggregator
    let manifest: CopyManifest?
    private let lock = NSLock()
    private var created: [URL] = []
    private var folders: [(src: URL, dst: URL)] = []

    init(flag: CancelFlag, progress: ProgressAggregator, manifest: CopyManifest?) {
        self.flag = flag; self.progress = progress; self.manifest = manifest
    }

    func noteCreated(_ url: URL) { lock.lock(); created.append(url); lock.unlock() }

    /// A folder this run made, as opposed to one a merge entered.
    func noteFolder(_ src: URL, _ dst: URL) { lock.lock(); folders.append((src, dst)); lock.unlock() }

    /// Gives the new folders their source's dates, tags and mode. Runs once they are full: filling a folder
    /// changes its dates, and a read-only mode would refuse the fill. Children first, for the same two reasons.
    func finishFolders() throws {
        lock.lock(); let items = folders; lock.unlock()
        for folder in items.reversed() { try copyFolderMetadata(from: folder.src, to: folder.dst) }
    }

    func removeCreated() throws {
        lock.lock(); let items = created; lock.unlock()
        for url in items.reversed() { try discardStaged(url) }
    }
}

/// Tags and other extended attributes, ACLs, mode and dates. Not COPYFILE_STAT: its flags would lock a locked folder's copy before the final rename.
private func copyFolderMetadata(from src: URL, to dst: URL) throws {
    do {
        guard copyfile(src.path, dst.path, nil, copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let fm = FileManager.default
        let attributes = try fm.attributesOfItem(atPath: src.path)
        try fm.setAttributes(attributes.filter { $0.key == .creationDate || $0.key == .modificationDate },
                             ofItemAtPath: dst.path)
    } catch {
        throw TransferError(.external, "Could not keep the folder's attributes:\(error.localizedDescription)", path: src.path)
    }
}

// MARK: Verification before a move deletes its source

/// Where each source item went, so verification can catch anything the copy never saw.
final class CopyManifest: @unchecked Sendable {
    private let lock = NSLock()
    private var destinations: [String: URL] = [:]
    func record(_ src: URL, _ dst: URL) { lock.lock(); destinations[src.path] = dst; lock.unlock() }
    func destination(of src: URL) -> URL? { lock.lock(); defer { lock.unlock() }; return destinations[src.path] }
}

private func verificationFailure(_ reason: String, _ src: URL) -> TransferError {
    TransferError(.external, "Move stopped and the source was kept:\(reason)", path: src.path)
}

/// Walks the source as it is now: every item must have been copied and must match its copy.
private func verifyItem(_ src: URL, against manifest: CopyManifest, flag: CancelFlag) throws {
    if flag.isSet { throw CancellationError() }
    guard let dst = manifest.destination(of: src) else {
        throw verificationFailure("\(src.lastPathComponent) appeared during the move", src)
    }
    var srcInfo = stat(), dstInfo = stat()
    guard lstat(src.path, &srcInfo) == 0 else { throw verificationFailure(String(cString: strerror(errno)), src) }
    guard lstat(dst.path, &dstInfo) == 0 else { throw verificationFailure("the copy of \(src.lastPathComponent) is missing", src) }
    guard srcInfo.st_mode & S_IFMT == dstInfo.st_mode & S_IFMT else {
        throw verificationFailure("the copy of \(src.lastPathComponent) has a different type", src)
    }
    let fm = FileManager.default
    do {
        switch srcInfo.st_mode & S_IFMT {
        case S_IFDIR:
            for name in try fm.contentsOfDirectory(atPath: src.path) {
                try verifyItem(src.appendingPathComponent(name), against: manifest, flag: flag)
            }
        case S_IFLNK:
            guard try fm.destinationOfSymbolicLink(atPath: src.path) == fm.destinationOfSymbolicLink(atPath: dst.path) else {
                throw verificationFailure("the copy of \(src.lastPathComponent) differs", src)
            }
        case S_IFREG:
            guard srcInfo.st_size == dstInfo.st_size, try sameContent(src, dst, flag: flag) else {
                throw verificationFailure("the copy of \(src.lastPathComponent) differs", src)
            }
        default:
            break   // devices, sockets and FIFOs have no content to compare, and reading one could block
        }
    } catch let error as TransferError {
        throw error
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        throw verificationFailure(error.localizedDescription, src)
    }
}

private func sameContent(_ a: URL, _ b: URL, flag: CancelFlag) throws -> Bool {
    let fileA = try FileHandle(forReadingFrom: a), fileB = try FileHandle(forReadingFrom: b)
    defer {
        try? fileA.close()
        try? fileB.close()
    }
    while true {
        if flag.isSet { throw CancellationError() }
        let chunkA = try fileA.read(upToCount: 1 << 20) ?? Data()
        let chunkB = try fileB.read(upToCount: 1 << 20) ?? Data()
        guard chunkA == chunkB else { return false }
        if chunkA.isEmpty { return true }
    }
}

// MARK: Staged commit

/// `lstat` existence: a dangling symlink is an existing item, unlike `FileManager.fileExists`.
func itemExists(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0
}

/// Unlike `FileManager.fileExists(isDirectory:)`, false for a symlink to a folder.
func isRealDirectory(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
}

private let stagingPrefix = ".hspace-transfer-"

/// Hidden sibling of the destination, so the final rename stays on one volume and is atomic.
/// The name holds the process id, so a later run can tell a crash's leftover from a transfer still running.
private func stagingURL(for destination: URL) -> URL {
    destination.deletingLastPathComponent()
        .appendingPathComponent("\(stagingPrefix)p\(getpid())-\(UUID().uuidString)")
}

/// Names without a process id come from older versions, which no longer run.
private func stagingOwnerIsRunning(_ name: String) -> Bool {
    let rest = name.dropFirst(stagingPrefix.count)
    guard rest.first == "p", let id = rest.dropFirst().split(separator: "-").first,
          let pid = pid_t(id) else { return false }
    return kill(pid, 0) == 0 || errno == EPERM
}

/// Moves what a crash left in these folders to the Trash. Never deletes: during a replace, a staged item can be
/// the only copy of the user's file. Best effort, because a leftover that stays costs disk space and nothing else,
/// and it must not stop the transfer the user asked for. Staged items deeper inside a merge are not reached.
func sweepLeftovers(in folders: Set<URL>) {
    let fm = FileManager.default
    for folder in folders {
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
        for name in names where name.hasPrefix(stagingPrefix) && !stagingOwnerIsRunning(name) {
            try? fm.trashItem(at: folder.appendingPathComponent(name), resultingItemURL: nil)
        }
    }
}

/// Renames `src` to `dst`, failing if `dst` exists by then.
private func renameExclusive(_ src: URL, to dst: URL) throws {
    var failure: Int32 = 0
    if renamex_np(src.path, dst.path, UInt32(RENAME_EXCL)) != 0 {
        failure = errno
        if failure == ENOTSUP || failure == EINVAL {
            // File systems without RENAME_EXCL (exFAT, SMB)
            failure = itemExists(dst) ? EEXIST : (rename(src.path, dst.path) == 0 ? 0 : errno)
        }
    }
    guard failure == 0 else {
        throw TransferError(.external, "Could not finish:\(String(cString: strerror(failure)))", path: dst.path)
    }
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
    // Its folders may already carry a read-only source's mode
    if isRealDirectory(staged), let walker = FileManager.default.enumerator(atPath: staged.path) {
        chmod(staged.path, 0o700)
        while let child = walker.nextObject() as? String {
            let url = staged.appendingPathComponent(child)
            if isRealDirectory(url) { chmod(url.path, 0o700) }
        }
    }
    do { try FileManager.default.removeItem(at: staged) } catch {
        throw TransferError(.external, "Stopped, but partial output could not be removed:\(error.localizedDescription)",
                            path: staged.path)
    }
}

/// copyfile callback context box (passed into the C callback via STATUS_CTX)
private final class CopyContext {
    let flag: CancelFlag
    let progress: ProgressAggregator
    let srcPath: String
    init(flag: CancelFlag, progress: ProgressAggregator, srcPath: String) {
        self.flag = flag; self.progress = progress; self.srcPath = srcPath
    }
}

private func copyOneFileSync(from src: URL, to dst: URL,
                             flag: CancelFlag, progress: ProgressAggregator) throws {
    if flag.isSet { throw CancellationError() }
    let state = copyfile_state_alloc()
    defer { copyfile_state_free(state) }

    let box = CopyContext(flag: flag, progress: progress, srcPath: src.path)
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
            box.progress.currentFile(bytes: Int64(copied), path: box.srcPath)
        }
        return Int32(COPYFILE_CONTINUE)
    }

    copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), ctx.toOpaque())
    copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB),
                       unsafeBitCast(callback, to: UnsafeRawPointer.self))

    // COPYFILE_CLONE: instant APFS clone on the same volume; falls back to a real copy across volumes
    // COPYFILE_EXCL: a file that appeared after the conflict check fails the copy with EEXIST instead of being overwritten
    let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE | COPYFILE_NOFOLLOW | COPYFILE_EXCL)
    let rc = copyfile(src.path, dst.path, state, flags)

    if rc < 0 {
        let savedErrno = errno   // snapshot first: removeItem clobbers errno
        // Partial-file cleanup: with EXCL, EEXIST means this run created nothing and the file belongs to someone else
        if savedErrno != EEXIST { try? FileManager.default.removeItem(at: dst) }
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
    // Progress names the source: the destination is a temporary name until the entry commits
    progress.fileFinished(bytes: Int64(size), path: src.path)
}
