import Foundation
import HSpaceContracts
@testable import HSpaceKernel
import Testing

/// A node that stops until told to finish, so that a test can hold operations open.
private final class HeldNode: OperationNode, @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var open = false

    func execute(_ spec: OperationSpec, context: NodeContext) async throws -> OperationReceipt {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let run = lock.withLock { () -> Bool in
                if !open { waiters.append(waiter) }
                return open
            }
            if run { waiter.resume() }
        }
        try Task.checkCancellation()
        return OperationReceipt(id: context.operationID, filesDone: 1, bytesDone: 0, duration: 0)
    }

    func release() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            open = true
            defer { waiters = [] }
            return waiters
        }
        pending.forEach { $0.resume() }
    }
}

/// Starts everything at once, and reports what happened to it.
private final class OpenRunQueue: RunQueue, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [UUID] = []
    private var finishedList: [UUID] = []
    private var withdrawnList: [UUID] = []
    private var isHeld = false
    private var wake: (@Sendable () -> Void)?

    var finishedIDs: [UUID] { lock.withLock { finishedList } }
    var withdrawnIDs: [UUID] { lock.withLock { withdrawnList } }

    func hold(_ value: Bool) { lock.withLock { isHeld = value } }

    func enqueue(_ id: UUID, spec: OperationSpec) { lock.withLock { waiting.append(id) } }

    func takeRunnable() -> [UUID] {
        lock.withLock {
            guard !isHeld else { return [] }
            defer { waiting = [] }
            return waiting
        }
    }

    func withdraw(_ id: UUID) {
        lock.withLock {
            withdrawnList.append(id)
            waiting.removeAll { $0 == id }
        }
    }

    func finished(_ id: UUID) { lock.withLock { finishedList.append(id) } }
    func setWakeHandler(_ handler: @escaping @Sendable () -> Void) { lock.withLock { wake = handler } }
    func fireWake() { lock.withLock { wake }?() }
}

private func until(_ kernel: OperationKernel, _ id: UUID, _ matches: (RunState) -> Bool) async throws {
    for _ in 0..<500 {
        if let state = await kernel.projection(id)?.state, matches(state) { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Operation did not reach the expected state")
}

/// Keeps count of how many panels are open at once.
private actor Panel: ConflictArbiter {
    private var open = 0
    private(set) var most = 0

    func arbitrate(operation id: UUID, conflicts: [FileConflict]) async -> [URL: ConflictDecision]? {
        open += 1
        most = max(most, open)
        try? await Task.sleep(for: .milliseconds(20))
        open -= 1
        return [:]
    }
}

private struct AskingNode: OperationNode {
    func execute(_ spec: OperationSpec, context: NodeContext) async throws -> OperationReceipt {
        let url = URL(fileURLWithPath: "/x")
        _ = await context.resolveConflicts([FileConflict(source: url, existing: url, bothDirectories: false)])
        return OperationReceipt(id: context.operationID, filesDone: 0, bytesDone: 0, duration: 0)
    }
}

@Suite struct KernelQueueTests {
    private let spec = OperationSpec(kind: .copy, sources: [], destination: nil)

    @Test func theDefaultQueueRunsOneAtATime() async throws {
        let node = HeldNode()
        let kernel = OperationKernel()
        await kernel.register(node, for: [.copy])
        let first = await kernel.submit(spec)
        let second = await kernel.submit(spec)
        try await until(kernel, first) { $0 == .scanning }
        #expect(await kernel.projection(second)?.state == .pending)
        node.release()
        try await until(kernel, second) { $0 == .completed }
    }

    @Test func aQueueCanRunSeveralAtOnce() async throws {
        let node = HeldNode()
        let queue = OpenRunQueue()
        let kernel = OperationKernel(queue: queue)
        await kernel.register(node, for: [.copy])
        let first = await kernel.submit(spec)
        let second = await kernel.submit(spec)
        try await until(kernel, first) { $0 == .scanning }
        try await until(kernel, second) { $0 == .scanning }
        node.release()
        try await until(kernel, first) { $0 == .completed }
        try await until(kernel, second) { $0 == .completed }
        #expect(Set(queue.finishedIDs) == [first, second])
    }

    @Test func aWakeStartsWhatTheQueueHeldBack() async throws {
        let node = HeldNode()
        node.release()
        let queue = OpenRunQueue()
        queue.hold(true)
        let kernel = OperationKernel(queue: queue)
        await kernel.register(node, for: [.copy])
        let id = await kernel.submit(spec)
        #expect(await kernel.projection(id)?.state == .pending)
        queue.hold(false)
        queue.fireWake()
        try await until(kernel, id) { $0 == .completed }
    }

    @Test func cancellingWhileQueuedTellsTheQueue() async throws {
        let queue = OpenRunQueue()
        queue.hold(true)
        let kernel = OperationKernel(queue: queue)
        let id = await kernel.submit(spec)
        await kernel.cancel(id)
        #expect(await kernel.projection(id)?.state == .cancelled)
        #expect(queue.withdrawnIDs == [id])
    }

    @Test func cancellingWhileRunningTellsTheQueueAndTheTask() async throws {
        let node = HeldNode()
        let queue = OpenRunQueue()
        let kernel = OperationKernel(queue: queue)
        await kernel.register(node, for: [.copy])
        let id = await kernel.submit(spec)
        try await until(kernel, id) { $0 == .scanning }
        await kernel.cancel(id)
        #expect(queue.withdrawnIDs == [id])
        node.release()
        try await until(kernel, id) { $0 == .cancelled }
        #expect(queue.finishedIDs == [id])
    }

    @Test func aKindWithNoNodeLeavesTheQueue() async throws {
        let queue = OpenRunQueue()
        let kernel = OperationKernel(queue: queue)
        let id = await kernel.submit(spec)
        try await until(kernel, id) { $0.isTerminal }
        #expect(queue.finishedIDs == [id])
    }

    @Test func conflictPanelsShowOneAtATime() async throws {
        let panel = Panel()
        let kernel = OperationKernel(queue: OpenRunQueue())
        await kernel.register(AskingNode(), for: [.copy])
        await kernel.setArbiter(panel)
        var ids: [UUID] = []
        for _ in 0..<3 { ids.append(await kernel.submit(spec)) }
        for id in ids { try await until(kernel, id) { $0 == .completed } }
        #expect(await panel.most == 1)
    }
}
