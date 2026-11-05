import Foundation
import HSpaceContracts

/// Transfer node (copy / move / duplicate). Constructor injection only (Axiom 2: no global mutable state).
public struct TransferNode: OperationNode {
    private let pauseGate: (@Sendable (UUID) -> Void)?

    /// `pauseGate` is called on an I/O thread before each file and during long ones, and may block there to pause the operation.
    public init(pauseGate: (@Sendable (UUID) -> Void)? = nil) {
        self.pauseGate = pauseGate
    }

    public func execute(_ spec: OperationSpec, context: NodeContext) async throws -> OperationReceipt {
        let started = Date()
        let plan = try makePlan(spec)
        try rejectSelfNesting(plan)

        // Micro-step 1: pre-scan totals (progress denominator)
        let scan = try preScan(sources: plan.entries.map(\.source))
        context.report(.scanTotals(files: scan.total.files, bytes: scan.total.bytes))

        // Micro-step 2: conflict detection + suspend for decisions
        let resolved = try await resolveConflicts(plan: plan, context: context)
        sweepLeftovers(in: Set(resolved.map { $0.destination.deletingLastPathComponent() }))

        // Micro-step 3: per-file transfer (cooperative cancellation reaches the copyfile callback via CancelFlag)
        let flag = CancelFlag(operationID: context.operationID, pauseGate: pauseGate)
        let progress = ProgressAggregator(report: context.report)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            for entry in resolved {
                try await transferEntry(entry, mode: plan.mode, flag: flag, progress: progress,
                                        entryTotals: scan.perSource[entry.source] ?? ScanTotals())
            }
            return OperationReceipt(id: context.operationID,
                                    filesDone: progress.snapshotFiles(),
                                    bytesDone: progress.snapshotBytes(),
                                    duration: Date().timeIntervalSince(started),
                                    createdURLs: resolved.map(\.destination))
        } onCancel: {
            flag.set()
        }
    }
}
