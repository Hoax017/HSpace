import Foundation
import HSpaceContracts

/// Construction factory + entry point (Axiom 2: no global state; the cache is instance-private).
public actor FolderSize: FolderSizing {
    // Derived cache (non-authoritative, discardable at any time): path → computed bytes.
    private var cache: [URL: Int64] = [:]

    // Deep enumeration concurrency bound: at most maxConcurrent at once, the rest queue as continuations (FIFO).
    // The deep enumeration itself runs on a detached task without blocking the actor executor, so concurrency is meaningful.
    private let maxConcurrent = 2
    private var activeScans = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func size(of url: URL) async throws -> Int64 {
        if let cached = cache[url] { return cached }

        await acquireSlot()
        defer { releaseSlot() }

        try Task.checkCancellation()   // exit early if cancelled while queued
        let total = try await runEnumeration(url)
        cache[url] = total
        return total
    }

    public func invalidate(_ url: URL) {
        cache[url] = nil
    }

    // MARK: - Concurrency gate (counter + continuation queue; the count stays put on hand-off, keeping a strict maxConcurrent cap)

    private func acquireSlot() async {
        if activeScans < maxConcurrent {
            activeScans += 1
            return
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters.append(c)
        }
        // Woken by releaseSlot = slot held (handed over by the previous holder; activeScans unchanged)
    }

    private func releaseSlot() {
        if waiters.isEmpty {
            activeScans -= 1
        } else {
            waiters.removeFirst().resume()   // hand the slot to the head of the queue
        }
    }

    // MARK: - Deep enumeration (detached to background, cancellation forwarded via the handle)

    private func runEnumeration(_ url: URL) async throws -> Int64 {
        let handle = TaskHandleBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int64, any Error>) in
                let work = Task.detached(priority: .utility) {
                    do { cont.resume(returning: try directoryAllocatedSize(url)) }
                    catch { cont.resume(throwing: error) }
                }
                handle.set(work)
            }
        } onCancel: {
            handle.cancel()   // forward cancellation → Task.isCancelled becomes true in the detached task → the enumeration loop throws
        }
    }
}
