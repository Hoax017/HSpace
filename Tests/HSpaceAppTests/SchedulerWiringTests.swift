import Foundation
import HSpaceContracts
import HSpaceKernel
import HSpaceTestSupport
import Scheduler
import Testing
import Transfer
@testable import HSpaceApp

private struct SkipEverything: ConflictArbiter {
    func arbitrate(operation id: UUID, conflicts: [FileConflict]) async -> [URL: ConflictDecision]? {
        Dictionary(uniqueKeysWithValues: conflicts.map { ($0.source, .skip) })
    }
}

private final class FirstCall: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func take() -> Bool {
        lock.withLock {
            defer { used = true }
            return !used
        }
    }
}

/// The Scheduler pod behind the real kernel and Transfer.
@Suite struct SchedulerWiringTests {
    private func until(_ kernel: OperationKernel, _ id: UUID, _ matches: (RunState) -> Bool) async throws {
        for _ in 0..<1000 {
            if let state = await kernel.projection(id)?.state, matches(state) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Operation did not reach the expected state")
    }

    private func fixture() throws -> (dir: URL, source: URL, target: URL) {
        let dir = try FaultFixture.tempDir("hspace-wiring")
        let source = dir.appendingPathComponent("source.txt")
        try FaultFixture.write(to: source)
        let target = dir.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return (dir, source, target)
    }

    @Test func aPausedQueueCopiesNothingUntilResumed() async throws {
        let (dir, source, target) = try fixture()
        defer { FaultFixture.remove(dir) }
        let scheduler = Scheduler()
        let kernel = OperationKernel(queue: SchedulerRunQueue(scheduler))
        await kernel.register(TransferNode(pauseGate: { scheduler.waitWhilePaused($0) }), for: [.copy])
        scheduler.pauseAll()
        let id = await kernel.submit(OperationSpec(kind: .copy, sources: [source], destination: target))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await kernel.projection(id)?.state == .pending)
        scheduler.resumeAll()
        try await until(kernel, id) { $0 == .completed }
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("source.txt").path))
    }

    @Test func aPausedRunningCopyCanBeCancelled() async throws {
        let (dir, source, target) = try fixture()
        defer { FaultFixture.remove(dir) }
        let scheduler = Scheduler()
        let kernel = OperationKernel(queue: SchedulerRunQueue(scheduler))
        let firstCall = FirstCall()
        await kernel.register(TransferNode(pauseGate: { id in
            if firstCall.take() { scheduler.pause(id) }
            scheduler.waitWhilePaused(id)
        }), for: [.copy])
        let id = await kernel.submit(OperationSpec(kind: .copy, sources: [source], destination: target))
        for _ in 0..<1000 where scheduler.snapshot().status(of: id)?.phase != .paused {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(scheduler.snapshot().status(of: id)?.phase == .paused)
        await kernel.cancel(id)
        try await until(kernel, id) { $0.isTerminal }
        #expect(await kernel.projection(id)?.state == .cancelled)
        #expect(scheduler.snapshot().jobs.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    @Test func overlappingCopiesRunInOrder() async throws {
        let (dir, source, target) = try fixture()
        defer { FaultFixture.remove(dir) }
        let scheduler = Scheduler(maxConcurrent: 4)
        let kernel = OperationKernel(queue: SchedulerRunQueue(scheduler))
        await kernel.register(TransferNode(), for: [.copy])
        await kernel.setArbiter(SkipEverything())
        let spec = OperationSpec(kind: .copy, sources: [source], destination: target)
        let first = await kernel.submit(spec)
        let second = await kernel.submit(spec)
        #expect(scheduler.snapshot().status(of: second)?.phase != .running)
        try await until(kernel, first) { $0.isTerminal }
        try await until(kernel, second) { $0.isTerminal }
        #expect(await kernel.projection(second)?.state == .completed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path) == ["source.txt"])
    }
}
