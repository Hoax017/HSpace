import Foundation

/// The queue itself: thread-safe, so the kernel can use it synchronously and a copy thread can stop on it.
/// One instance is shared by the kernel and the task window (constructor injection, Axiom 2).
public final class Scheduler: @unchecked Sendable {
    /// Guards everything below, and wakes the threads stopped in `waitWhilePaused`
    private let condition = NSCondition()
    private var state: QueueState
    private var observers: [UUID: AsyncStream<SchedulerSnapshot>.Continuation] = [:]
    private var wake: (@Sendable () -> Void)?

    public init(maxConcurrent: Int = 2) {
        state = QueueState(maxConcurrent: maxConcurrent)
    }

    // MARK: Kernel side

    /// Called after a change that may let a job start
    public func setWakeHandler(_ handler: @escaping @Sendable () -> Void) {
        condition.withLock { wake = handler }
    }

    public func enqueue(_ request: SchedulerRequest) {
        change(wakes: false) { $0.enqueue(request) }
    }

    /// Returns the jobs that may start now and marks them running.
    public func takeRunnable() -> [UUID] {
        var started: [UUID] = []
        change(wakes: false) { started = $0.takeRunnable() }
        return started
    }

    /// The job was cancelled. A queued job leaves at once; a running one is let go of its pause and leaves through `finished`.
    public func withdraw(_ id: UUID) {
        change(wakes: false) { state in
            if state.jobs[id]?.running == true {
                state.jobs[id]?.withdrawn = true
            } else {
                state.jobs[id] = nil
            }
        }
    }

    public func finished(_ id: UUID) {
        change(wakes: false) { $0.jobs[id] = nil }
    }

    /// Blocks the calling thread while the job is paused. Call it only from a thread that may block, never from the
    /// Swift concurrency pool. Returns at once for a job that is not paused, and when the job is withdrawn.
    public func waitWhilePaused(_ id: UUID) {
        condition.lock()
        defer { condition.unlock() }
        while state.mustWait(id) { condition.wait() }
    }

    // MARK: User side

    /// false when the job cannot stop where it is now.
    @discardableResult
    public func pause(_ id: UUID) -> Bool {
        var paused = false
        change { state in
            guard let job = state.jobs[id], !job.running || job.request.pausableWhileRunning else { return }
            state.jobs[id]?.held = true
            paused = true
        }
        return paused
    }

    public func resume(_ id: UUID) {
        change { $0.jobs[id]?.held = false }
    }

    public func pauseAll() {
        change { $0.isPaused = true }
    }

    public func resumeAll() {
        change { state in
            state.isPaused = false
            for id in state.jobs.keys { state.jobs[id]?.held = false }
        }
    }

    public func setPriority(_ priority: SchedulerPriority, for id: UUID) {
        change { $0.jobs[id]?.priority = priority }
    }

    public func setMaxConcurrent(_ count: Int) {
        change { $0.maxConcurrent = max(1, count) }
    }

    // MARK: Observing

    public func snapshot() -> SchedulerSnapshot {
        condition.withLock { state.snapshot() }
    }

    /// The current snapshot, then one after every change. Nothing is sent while nothing changes.
    public func changes() -> AsyncStream<SchedulerSnapshot> {
        let key = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            condition.withLock {
                observers[key] = continuation
                continuation.yield(state.snapshot())
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.condition.withLock { self.observers[key] = nil }
            }
        }
    }

    private func change(wakes: Bool = true, _ mutate: (inout QueueState) -> Void) {
        condition.lock()
        mutate(&state)
        let snapshot = state.snapshot()
        for observer in observers.values { observer.yield(snapshot) }
        let handler = wakes ? wake : nil
        condition.broadcast()
        condition.unlock()
        handler?()
    }
}
