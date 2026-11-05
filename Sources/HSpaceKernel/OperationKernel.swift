import Foundation
import HSpaceContracts

// Node contracts (NodeEvent/NodeContext/OperationNode/ConflictArbiter) live in the HSpaceContracts vocabulary;
// this kernel provides only generic mechanisms: queueing / scheduling / cancellation / progress aspect / atomic Run state machine commits (BG-3: zero business branches).

// MARK: - Run queue (who starts next; a generic seam, so that the kernel knows no scheduling policy, BG-3)

/// Decides which submitted operations may start. Implementations must be thread-safe and must not call back synchronously.
public protocol RunQueue: AnyObject, Sendable {
    func enqueue(_ id: UUID, spec: OperationSpec)
    /// The operations that may start now; the queue counts them as running until `finished`
    func takeRunnable() -> [UUID]
    /// The operation was cancelled, whether it is running or not
    func withdraw(_ id: UUID)
    func finished(_ id: UUID)
    /// `handler` runs after anything that may let an operation start
    func setWakeHandler(_ handler: @escaping @Sendable () -> Void)
}

/// Default queue: one at a time, first come first served.
public final class SerialRunQueue: RunQueue, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [UUID] = []
    private var running: UUID?

    public init() {}

    public func enqueue(_ id: UUID, spec: OperationSpec) { lock.withLock { waiting.append(id) } }

    public func takeRunnable() -> [UUID] {
        lock.withLock {
            guard running == nil, !waiting.isEmpty else { return [] }
            let next = waiting.removeFirst()
            running = next
            return [next]
        }
    }

    public func withdraw(_ id: UUID) { lock.withLock { waiting.removeAll { $0 == id } } }

    public func finished(_ id: UUID) { lock.withLock { if running == id { running = nil } } }

    public func setWakeHandler(_ handler: @escaping @Sendable () -> Void) {}
}

// MARK: - Kernel (sole Commit Owner: atomic commits of the Run state machine, BG-5)

public actor OperationKernel {
    private struct Run {
        let id: UUID
        let spec: OperationSpec
        var state: RunState = .pending
        var filesDone = 0
        var filesTotal = 0
        var bytesDone: Int64 = 0
        var bytesTotal: Int64 = 0
        var currentPath: String?
        var task: Task<Void, Never>?
        let startedAt = Date()
    }

    private var nodes: [OperationSpec.Kind: any OperationNode] = [:]
    private var arbiter: (any ConflictArbiter)?
    private var runs: [UUID: Run] = [:]
    /// Retained node receipts for successful terminal states (createdURLs / trashedItems for UI selection and undo; purely derived archive, not a state machine branch)
    private var receipts: [UUID: OperationReceipt] = [:]
    private var order: [UUID] = []
    private var observers: [UUID: AsyncStream<OperationProjection>.Continuation] = [:]
    private let queue: any RunQueue
    /// The conflict panel shows one question at a time, however many operations run
    private var arbitrationTail: Task<Void, Never>?

    public init(queue: any RunQueue = SerialRunQueue()) {
        self.queue = queue
        queue.setWakeHandler { [weak self] in
            Task { await self?.pump() }
        }
    }

    // MARK: Orchestration config (the What is injected declaratively at app startup, BG-2)

    public func register(_ node: any OperationNode, for kinds: [OperationSpec.Kind]) {
        for k in kinds { nodes[k] = node }
    }

    public func setArbiter(_ a: any ConflictArbiter) { arbiter = a }

    // MARK: Command surface (the presentation layer's only entry point, BG-1)

    @discardableResult
    public func submit(_ spec: OperationSpec) -> UUID {
        let id = UUID()
        runs[id] = Run(id: id, spec: spec)
        order.append(id)
        publish(id)
        queue.enqueue(id, spec: spec)
        pump()
        return id
    }

    public func cancel(_ id: UUID) {
        guard var run = runs[id], !run.state.isTerminal else { return }
        if let task = run.task {
            task.cancel()
            queue.withdraw(id)
        } else {
            run.state = .cancelled
            runs[id] = run
            publish(id)
            queue.withdraw(id)
            pump()
        }
    }

    // MARK: Query / Subscribe surface (read-only projections)

    public func projections() -> AsyncStream<OperationProjection> {
        let key = UUID()
        return AsyncStream { continuation in
            observers[key] = continuation
            for id in order { if let p = projection(id) { continuation.yield(p) } }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(key) }
            }
        }
    }

    public func projection(_ id: UUID) -> OperationProjection? {
        guard let r = runs[id] else { return nil }
        return OperationProjection(id: r.id, kind: r.spec.kind, state: r.state,
                                   filesDone: r.filesDone, filesTotal: r.filesTotal,
                                   bytesDone: r.bytesDone, bytesTotal: r.bytesTotal,
                                   currentPath: r.currentPath)
    }

    /// Receipt of a successful terminal state (createdURLs / trashedItems); nil when unfinished or unsuccessful
    public func receipt(_ id: UUID) -> OperationReceipt? { receipts[id] }

    // MARK: Internals: scheduling and state commits

    private func removeObserver(_ key: UUID) { observers[key] = nil }

    private func pump() {
        for id in queue.takeRunnable() { start(id) }
    }

    private func start(_ id: UUID) {
        guard var run = runs[id], run.state == .pending else {
            queue.finished(id)
            pump()
            return
        }
        guard let node = nodes[run.spec.kind] else {
            run.state = .failed(message: "no node registered for \(run.spec.kind.rawValue)", errorClass: .logic)
            runs[id] = run; publish(id)
            queue.finished(id)
            pump()
            return
        }
        run.state = .scanning
        let spec = run.spec
        run.task = Task { [weak self] in
            await self?.drive(id: id, node: node, spec: spec)
        }
        runs[id] = run
        publish(id)
    }

    private func drive(id: UUID, node: any OperationNode, spec: OperationSpec) async {
        let context = NodeContext(
            operationID: id,
            report: { [weak self] event in
                Task { await self?.apply(event, to: id) }
            },
            resolveConflicts: { [weak self] conflicts in
                await self?.arbitrateConflicts(id: id, conflicts: conflicts) ?? nil
            }
        )
        do {
            let receipt = try await node.execute(spec, context: context)
            receipts[id] = receipt
            commit(id) { run in
                run.filesDone = receipt.filesDone
                run.bytesDone = receipt.bytesDone
                // Partial failure is not completion: the state tells the truth. But the receipt **has already been stored**:
                // what really landed must stay undoable and truthfully reportable, not be dropped along with the state.
                if let first = receipt.failures.first {
                    run.state = .failed(
                        message: receipt.failures.count == 1
                            ? first.message
                            : "\(first.message) (\(receipt.failures.count - 1) more failed)",
                        errorClass: first.errorClass)
                } else {
                    run.state = .completed
                }
            }
        } catch is CancellationError {
            commit(id) { $0.state = .cancelled }
        } catch let error as any ClassifiedError {
            commit(id) { $0.state = .failed(message: error.localizedDescription, errorClass: error.errorClass) }
        } catch {
            commit(id) { $0.state = .failed(message: error.localizedDescription, errorClass: .transient) }
        }
        queue.finished(id)
        pump()
    }

    private func arbitrateConflicts(id: UUID, conflicts: [FileConflict]) async -> [URL: ConflictDecision]? {
        guard let arbiter else { return [:] }  // no arbiter = no conflict policy; by default everything is skipped and left to the node
        commit(id) { $0.state = .awaitingConflict }
        let previous = arbitrationTail
        let turn = Task { () -> [URL: ConflictDecision]? in
            await previous?.value
            return await arbiter.arbitrate(operation: id, conflicts: conflicts)
        }
        arbitrationTail = Task { _ = await turn.value }
        let decisions = await turn.value
        commit(id) { if !$0.state.isTerminal { $0.state = .running } }
        return decisions
    }

    private func apply(_ event: NodeEvent, to id: UUID) {
        commit(id) { run in
            switch event {
            case let .scanTotals(files, bytes):
                run.filesTotal = files
                run.bytesTotal = bytes
                if run.state == .scanning { run.state = .running }
            case let .progress(filesDone, bytesDone, currentPath):
                run.filesDone = filesDone
                run.bytesDone = bytesDone
                run.currentPath = currentPath
            }
        }
    }

    /// Sole state commit point: terminal states cannot transition again (spec 3.1)
    private func commit(_ id: UUID, _ mutate: (inout Run) -> Void) {
        guard var run = runs[id] else { return }
        let wasTerminal = run.state.isTerminal
        mutate(&run)
        if wasTerminal { return }
        runs[id] = run
        publish(id)
    }

    private func publish(_ id: UUID) {
        guard let p = projection(id) else { return }
        for c in observers.values { c.yield(p) }
    }
}
