import Foundation
import NSpaceContracts

/// Construction factory (Axiom 2: no global state, handles are produced by construction).
public struct DirectoryWatch: DirectoryWatching {
    public init() {}

    public func watch(_ path: URL) -> DirectoryWatcher {
        DirectoryWatcher(path: path)
    }
}

/// FSEvents watch handle: exposes the `signals` stream plus suspend/resume/stop controls.
///
/// Background pane suspension is a product north star: `suspend()` really stops the FSEventStream (zero callbacks, zero power),
/// `resume()` starts it again; `stop()` / deinit fully tear down the stream and finish the signal stream.
public final class DirectoryWatcher: Sendable {
    /// Directory change signal stream (0.3s latency coalesces bursts; bufferingNewest(1) collapses multiple changes into one pending reload).
    public let signals: AsyncStream<Void>
    /// Non-nil when FSEventStream creation fails (transient); callers degrade to manual refresh (⌘R) without crashing.
    public var startupError: DirectoryWatchError? { pump.startupError }

    private let pump: WatchPump

    init(path: URL) {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.signals = stream
        self.pump = WatchPump(path: path, continuation: continuation)
        pump.start()
    }

    /// Suspends watching: stops the FSEventStream (no more callbacks) but keeps the handle for a later resume.
    public func suspend() { pump.suspend() }

    /// Resumes watching: restarts the FSEventStream, receiving only changes after the resume.
    public func resume() { pump.resume() }

    /// Stops and tears down watching, finishing the signal stream (idempotent).
    public func stop() { pump.stop() }

    deinit { pump.stop() }
}
