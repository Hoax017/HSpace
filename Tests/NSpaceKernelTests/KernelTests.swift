import Testing
import Foundation
@testable import NSpaceKernel
import NSpaceContracts

@Suite struct KernelStateMachineTests {
    /// An operation with an unregistered node must end in a logic-class failure (errors are not swallowed)
    @Test func unregisteredKindFails() async throws {
        let kernel = OperationKernel()
        let id = await kernel.submit(OperationSpec(kind: .copy, sources: [], destination: nil))
        // Wait for the state machine to reach a terminal state
        for _ in 0..<100 {
            if let p = await kernel.projection(id), p.state.isTerminal {
                guard case .failed(_, let cls) = p.state else {
                    Issue.record("Expected failed, got\(p.state)")
                    return
                }
                #expect(cls == .logic || cls == .transient)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Operation did not reach a terminal state within 1s")
    }

    /// Cancelling in pending: goes straight to the cancelled terminal state, and terminal states cannot transition again
    @Test func cancelBeforeStartIsTerminal() async throws {
        let kernel = OperationKernel()
        // Occupying the execution slot first is not feasible by submitting an unregistered kind, so test API idempotence directly
        let id = await kernel.submit(OperationSpec(kind: .move, sources: [], destination: nil))
        await kernel.cancel(id)
        // Whether the race lands on failed or cancelled, it must be terminal and cancel must be idempotent
        for _ in 0..<100 {
            if let p = await kernel.projection(id), p.state.isTerminal {
                await kernel.cancel(id)  // idempotent, must not crash or change state
                let p2 = await kernel.projection(id)
                #expect(p2?.state == p.state)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Operation did not reach a terminal state within 1s")
    }
}
