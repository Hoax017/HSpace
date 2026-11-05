import Foundation
import HSpaceContracts
import HSpaceTestSupport
import Testing
import Transfer

/// L40: a copy stops at the gate, and comes out of it cleanly either way.
@Suite struct TransferPauseTests {
    private final class Gate: @unchecked Sendable {
        let open = DispatchSemaphore(value: 0)
        let reached = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var calls = 0
        private var ids: Set<UUID> = []

        var seenIDs: Set<UUID> { lock.withLock { ids } }

        /// Stops the first caller; later calls pass
        func stop(_ id: UUID) {
            let first = lock.withLock { () -> Bool in
                ids.insert(id)
                calls += 1
                return calls == 1
            }
            guard first else { return }
            reached.signal()
            open.wait()
        }

        func waitUntilReached() async {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    self.reached.wait()
                    done.resume()
                }
            }
        }
    }

    private func fixture() throws -> (dir: URL, source: URL, target: URL) {
        let dir = try FaultFixture.tempDir("hspace-pause")
        let source = dir.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for index in 0..<3 { try FaultFixture.write(to: source.appendingPathComponent("\(index).txt")) }
        let target = dir.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return (dir, source, target)
    }

    private func context(_ id: UUID = UUID()) -> NodeContext {
        NodeContext(operationID: id, report: { _ in }, resolveConflicts: { _ in [:] })
    }

    @Test func aPausedCopyFinishesWhenReleased() async throws {
        let (dir, source, target) = try fixture()
        defer { FaultFixture.remove(dir) }
        let gate = Gate()
        let node = TransferNode(pauseGate: { gate.stop($0) })
        let id = UUID()
        let spec = OperationSpec(kind: .copy, sources: [source], destination: target)
        let run = Task { try await node.execute(spec, context: context(id)) }
        await gate.waitUntilReached()
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("folder").path))
        gate.open.signal()
        _ = try await run.value
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("folder/2.txt").path))
        #expect(gate.seenIDs == [id])
    }

    @Test func cancellingAPausedCopyLeavesNothing() async throws {
        let (dir, source, target) = try fixture()
        defer { FaultFixture.remove(dir) }
        let gate = Gate()
        let node = TransferNode(pauseGate: { gate.stop($0) })
        let spec = OperationSpec(kind: .copy, sources: [source], destination: target)
        let run = Task { try await node.execute(spec, context: context()) }
        await gate.waitUntilReached()
        run.cancel()
        gate.open.signal()
        await #expect(throws: CancellationError.self) { _ = try await run.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }
}
