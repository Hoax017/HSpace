import Foundation
import CoreServices
import HSpaceContracts

// Private concern: FSEventStream lifecycle + C callback trampoline.
// All mutable state is serialized by lock, hence @unchecked Sendable externally (the lock guarantees freedom from data races).

final class WatchPump: @unchecked Sendable {
    private let lock = NSLock()
    private let path: String
    private let continuation: AsyncStream<Void>.Continuation
    // A dedicated queue takes FSEvents callbacks, never the main thread (background zero-power rule).
    private let queue = DispatchQueue(label: "com.hoax017.hspace.directorywatch", qos: .utility)

    private var stream: FSEventStreamRef?
    private var running = false
    private var stopped = false
    private(set) var startupError: DirectoryWatchError?

    init(path: URL, continuation: AsyncStream<Void>.Continuation) {
        // FSEvents reports canonical realpath paths (/var → /private/var etc).
        // Note that Foundation's resolvingSymlinksInPath deliberately strips the /private prefix,
        // the opposite of FSEvents: POSIX realpath must be used to align, or the filter would kill every real signal
        if let rp = realpath(path.path, nil) {
            self.path = String(cString: rp)
            free(rp)
        } else {
            self.path = path.path
        }
        self.continuation = continuation
    }

    /// Called on the callback thread: delivers a signal only when an event hits "the directory itself or a direct child".
    /// FSEvents (FileEvents) reports recursively for the watched path: deep subtree changes are irrelevant to "this directory's listing",
    /// and without filtering, background build subtree noise is amplified into a full directory reload every 0.3s (the culprit behind 25%+ idle CPU).
    func emit(paths: [String]) {
        lock.lock(); let dead = stopped; let root = path; lock.unlock()
        guard !dead else { return }
        let normalizedRoot = root.hasSuffix("/") ? String(root.dropLast()) : root
        let relevant = paths.contains { p in
            let np = p.hasSuffix("/") ? String(p.dropLast()) : p
            return np == normalizedRoot
                || (np as NSString).deletingLastPathComponent == normalizedRoot
        }
        guard relevant else { return }
        continuation.yield(())
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard stream == nil, !stopped else { return }

        // info passes unretained self: WatchPump's lifetime covers the stream (stop/deinit always tear the stream down first), so nothing dangles.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let flags = UInt32(kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer)   // NoDefer: first change reports immediately, later ones coalesce by latency

        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault, watchCallback, &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3, flags) else {
            startupError = DirectoryWatchError(.transient, "Could not create FSEventStream: \(path)")
            continuation.finish()
            return
        }

        FSEventStreamSetDispatchQueue(s, queue)
        if FSEventStreamStart(s) {
            stream = s
            running = true
        } else {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            startupError = DirectoryWatchError(.transient, "Could not start FSEventStream: \(path)")
            continuation.finish()
        }
    }

    func suspend() {
        lock.lock(); defer { lock.unlock() }
        guard let s = stream, running, !stopped else { return }
        FSEventStreamStop(s)
        running = false
    }

    func resume() {
        lock.lock(); defer { lock.unlock() }
        guard let s = stream, !running, !stopped else { return }
        if FSEventStreamStart(s) { running = true }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        if let s = stream {
            if running { FSEventStreamStop(s) }
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
            running = false
        }
        continuation.finish()
    }
}

// C callback trampoline: recovers WatchPump (unretained) via the info pointer, parses event paths, filters and delivers.
private func watchCallback(
    _ streamRef: ConstFSEventStreamRef,
    _ info: UnsafeMutableRawPointer?,
    _ numEvents: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    // UseCFTypes is not set: eventPaths is a char** array
    let raw = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
    var paths: [String] = []
    paths.reserveCapacity(numEvents)
    for i in 0..<numEvents {
        if let cstr = raw[i] { paths.append(String(cString: cstr)) }
    }
    Unmanaged<WatchPump>.fromOpaque(info).takeUnretainedValue().emit(paths: paths)
}
