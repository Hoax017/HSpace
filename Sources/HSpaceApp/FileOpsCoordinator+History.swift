import AppKit
import HSpaceContracts
import OperationHistory

/// What must be known about an operation before it runs, to describe it afterwards.
struct HistoryTicket {
    let spec: OperationSpec
    let occupiedBefore: Set<String>
    let groupID: UUID?
    let groupTitle: String?
    let startedAt = Date()
}

/// Outcome of undoing one history line
enum HistoryUndoResult: Equatable {
    /// `leftInPlace`: items that joined something existing, which undo leaves alone
    case undone(leftInPlace: Int)
    /// Nothing was touched
    case refused([HistoryUndoBlocker])
    /// Stopped part way, or the user cancelled: the line stays undoable for what is left
    case stopped
}

extension FileOpsCoordinator {
    /// Everything submitted inside `body` undoes as one line, titled `title`.
    func historyGroup<T>(_ title: String, _ body: () async -> T) async -> T {
        let outer = activeHistoryGroup
        activeHistoryGroup = outer ?? (UUID(), title)
        defer { activeHistoryGroup = outer }
        return await body()
    }

    func historyTicket(for spec: OperationSpec) -> HistoryTicket? {
        guard history != nil else { return nil }
        return HistoryTicket(spec: spec, occupiedBefore: HistoryBuilder.occupiedTargets(of: spec),
                             groupID: activeHistoryGroup?.id, groupTitle: activeHistoryGroup?.title)
    }

    /// Records a finished operation, from what really landed.
    func recordHistory(_ ticket: HistoryTicket?, id: UUID) async {
        guard let ticket, let history, let state = await kernel.projection(id)?.state else { return }
        let receipt = await kernel.receipt(id)
        let steps = receipt.map {
            HistoryBuilder.steps(of: ticket.spec, receipt: $0, occupiedBefore: ticket.occupiedBefore, startedAt: ticket.startedAt)
        } ?? []
        let outcome: HistoryOutcome
        switch state {
        case .cancelled: outcome = .cancelled
        case .failed(let message, _): outcome = .failed(message)
        default: outcome = .completed
        }
        // Skipped work leaves nothing to tell: a Skip in the conflict panel is the only way to end here
        if outcome == .completed, steps.isEmpty, ticket.spec.kind != .delete { return }
        let spec = ticket.spec
        await history.record(HistoryEntry(
            groupID: ticket.groupID, groupTitle: ticket.groupTitle, kind: spec.kind.rawValue,
            names: Self.historyNames(spec), itemCount: max(spec.sources.count, steps.count), steps: steps, outcome: outcome))
        ProblemAlert.show(await history.takeProblem())
    }

    private nonisolated static func historyNames(_ spec: OperationSpec) -> [String] {
        let names = spec.sources.prefix(3).map(\.lastPathComponent)
        return names.isEmpty ? [spec.newName].compactMap { $0 } : names
    }

    /// Undoes one line, newest step first. Checks the whole line before touching anything,
    /// and stops at the first step that does not land, leaving the rest as it is.
    func undoHistory(_ group: HistoryGroup) async -> HistoryUndoResult {
        let plan = await Task.detached { HistoryUndoPlanner.plan(group) }.value
        guard plan.blockers.isEmpty else { return .refused(plan.blockers) }
        for action in plan.actions {
            guard await perform(action) else {
                reloadLists()
                return .stopped
            }
        }
        await history?.markUndone(group.id)
        reloadLists()
        return .undone(leftInPlace: plan.leftInPlace)
    }

    private func perform(_ action: HistoryUndoAction) async -> Bool {
        switch action {
        case .discard(let url):
            return await withCheckedContinuation { done in
                moveToTrash([url], recorded: false) { receipt in
                    done.resume(returning: receipt?.trashedItems.isEmpty == false)
                }
            }
        case .moveBack(let current, let original):
            let spec = OperationSpec(kind: .move, sources: [current], destination: original.deletingLastPathComponent())
            guard let receipt = await runUnrecorded(spec), receipt.failures.isEmpty, let landed = receipt.createdURLs.first else {
                return false
            }
            guard landed.lastPathComponent != original.lastPathComponent else { return true }
            return await perform(.renameBack(current: landed, originalName: original.lastPathComponent))
        case .renameBack(let current, let name):
            let spec = OperationSpec(kind: .rename, sources: [current], newName: name)
            let receipt = await runUnrecorded(spec)
            return receipt?.failures.isEmpty == true && receipt?.createdURLs.isEmpty == false
        case .restore(let item):
            return await withCheckedContinuation { done in
                restore([item]) { done.resume(returning: $0.restored == 1) }
            }
        }
    }
}
