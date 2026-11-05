import CryptoKit
import Foundation

// Private concern: reading files in chunks and feeding the digests

private let chunkSize = 1 << 20
/// Progress events per file are bounded, so a fast disk cannot flood the stream
private let progressStep: Int64 = 16 << 20

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

private struct Hashers {
    private var md5: Insecure.MD5?
    private var sha1: Insecure.SHA1?
    private var sha256: SHA256?

    init(_ algorithms: Set<HashAlgorithm>) {
        if algorithms.contains(.md5) { md5 = Insecure.MD5() }
        if algorithms.contains(.sha1) { sha1 = Insecure.SHA1() }
        if algorithms.contains(.sha256) { sha256 = SHA256() }
    }

    mutating func update(_ data: Data) {
        md5?.update(data: data)
        sha1?.update(data: data)
        sha256?.update(data: data)
    }

    func finalize() -> [HashAlgorithm: String] {
        var values: [HashAlgorithm: String] = [:]
        if let md5 { values[.md5] = hex(md5.finalize()) }
        if let sha1 { values[.sha1] = hex(sha1.finalize()) }
        if let sha256 { values[.sha256] = hex(sha256.finalize()) }
        return values
    }

    private func hex(_ digest: some Sequence<UInt8>) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Size of a regular file or a link's target. Anything else cannot be hashed.
private func fileSize(_ url: URL) throws -> Int64 {
    let values: URLResourceValues
    do {
        values = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
    } catch {
        throw FileHashError(.external, "\(url.lastPathComponent) cannot be read: \(error.localizedDescription)", path: url.path)
    }
    var resolved = values
    if values.isDirectory != true, let target = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]) {
        resolved = target
    }
    if resolved.isDirectory == true {
        throw FileHashError(.external, "\(url.lastPathComponent) is a folder.", path: url.path)
    }
    return Int64(resolved.fileSize ?? 0)
}

private func digest(of url: URL, algorithms: Set<HashAlgorithm>, flag: CancelFlag,
                    onBytes: (Int64) -> Void) throws -> FileDigest {
    let handle: FileHandle
    do {
        handle = try FileHandle(forReadingFrom: url)
    } catch {
        throw FileHashError(.external, "\(url.lastPathComponent) cannot be read: \(error.localizedDescription)", path: url.path)
    }
    defer { try? handle.close() }    // Read-only: closing cannot lose data
    var hashers = Hashers(algorithms)
    var total: Int64 = 0
    while true {
        if flag.isSet { throw CancellationError() }
        let chunk: Data?
        do {
            chunk = try autoreleasepool { try handle.read(upToCount: chunkSize) }
        } catch {
            throw FileHashError(.external, "Reading \(url.lastPathComponent) failed: \(error.localizedDescription)", path: url.path)
        }
        guard let chunk, !chunk.isEmpty else { break }
        hashers.update(chunk)
        total += Int64(chunk.count)
        onBytes(Int64(chunk.count))
    }
    return FileDigest(byteCount: total, values: hashers.finalize())
}

func hashStream(_ files: [URL], algorithms: Set<HashAlgorithm>) -> AsyncThrowingStream<HashEvent, any Error> {
    AsyncThrowingStream { continuation in
        let flag = CancelFlag()
        continuation.onTermination = { _ in flag.set() }
        // A plain thread rather than the cooperative pool: one slow disk must not hold a Swift concurrency thread for minutes
        DispatchQueue(label: "com.hoax017.hspace.filehash", qos: .userInitiated).async {
            var sizes: [URL: Int64] = [:]
            var failures: [URL: FileHashError] = [:]
            for url in files {
                do { sizes[url] = try fileSize(url) } catch let failure as FileHashError {
                    failures[url] = failure
                } catch {
                    failures[url] = FileHashError(.external, error.localizedDescription, path: url.path)
                }
            }
            let bytesTotal = sizes.values.reduce(0, +)
            var bytesDone: Int64 = 0
            for (index, url) in files.enumerated() {
                if flag.isSet { break }
                if let failure = failures[url] {
                    continuation.yield(.finished(FileHashOutcome(url: url, result: .failure(failure))))
                    continue
                }
                let snapshot = { HashProgress(filesDone: index, fileCount: files.count, bytesDone: bytesDone, bytesTotal: bytesTotal, current: url) }
                continuation.yield(.progress(snapshot()))
                var sinceReport: Int64 = 0
                do {
                    let value = try digest(of: url, algorithms: algorithms, flag: flag) { count in
                        bytesDone += count
                        sinceReport += count
                        if sinceReport >= progressStep {
                            sinceReport = 0
                            continuation.yield(.progress(snapshot()))
                        }
                    }
                    continuation.yield(.finished(FileHashOutcome(url: url, result: .success(value))))
                } catch let failure as FileHashError {
                    continuation.yield(.finished(FileHashOutcome(url: url, result: .failure(failure))))
                } catch {
                    break    // Cancelled
                }
            }
            continuation.finish()
        }
    }
}
