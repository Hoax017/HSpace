import Foundation
import NSpaceContracts

// Private concern: recursive allocated-byte summation + thread-safe box holding the detached task handle.

private let sizeKeys: Set<URLResourceKey> = [
    .isRegularFileKey, .isDirectoryKey,
    .totalFileAllocatedSizeKey, .fileSizeKey,
]

/// Recursive sum: deep-enumerates a directory's regular files; a single file returns its own allocation directly.
/// Checks Task.isCancelled each step for cooperative cancellation (throws CancellationError).
func directoryAllocatedSize(_ url: URL) throws -> Int64 {
    let fm = FileManager.default

    let rv: URLResourceValues
    do {
        rv = try url.resourceValues(forKeys: sizeKeys)
    } catch let e as NSError {
        let cls: ErrorClass = (e.domain == NSCocoaErrorDomain &&
            (e.code == NSFileReadNoPermissionError || e.code == NSFileReadNoSuchFileError))
            ? .external : .transient
        throw FolderSizeError(cls, e.localizedDescription, underlying: e)
    }

    if rv.isRegularFile == true {
        return fileBytes(rv)
    }
    guard rv.isDirectory == true else { return 0 }   // symlinks and special files are not counted

    guard let enumerator = fm.enumerator(
        at: url,
        includingPropertiesForKeys: Array(sizeKeys),
        options: [],
        errorHandler: nil) else {
        throw FolderSizeError(.external, "Could not enumerate folder: \(url.path)")
    }

    var total: Int64 = 0
    for case let child as URL in enumerator {
        try Task.checkCancellation()   // cooperative cancellation checkpoint
        guard let crv = try? child.resourceValues(forKeys: sizeKeys),
              crv.isRegularFile == true else { continue }
        total += fileBytes(crv)
    }
    return total
}

// Prefers totalFileAllocatedSize (real allocation including metadata and block alignment), falls back to fileSize (logical bytes).
private func fileBytes(_ rv: URLResourceValues) -> Int64 {
    Int64(rv.totalFileAllocatedSize ?? rv.fileSize ?? 0)
}

/// Holds the detached task handle for forwarding cancellation; the lock keeps set/cancel race-free.
final class TaskHandleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false

    func set(_ task: Task<Void, Never>) {
        lock.lock(); defer { lock.unlock() }
        if cancelled { task.cancel() } else { self.task = task }
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        task?.cancel()
    }
}
