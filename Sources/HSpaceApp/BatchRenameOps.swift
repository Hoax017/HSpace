import AppKit
import BatchRename

/// Runs rename batches for one window and puts each on that window's undo stack as a single action.
/// The rename engine is the BatchRename pod: a batch has to be all or nothing, which no per-item kernel operation can promise.
@MainActor
final class BatchRenameOps {
    private let coordinator: FileOpsCoordinator
    /// The latest undo or redo: UndoManager cannot wait for async work, tests can
    private(set) var lastReversal: Task<Void, Never>?

    init(coordinator: FileOpsCoordinator) {
        self.coordinator = coordinator
    }

    /// Applies a plan. Throws what the pod throws; nothing is registered unless the batch landed.
    func apply(_ plan: RenamePlan, progress: @escaping @Sendable (Int, Int) -> Void) async throws -> RenameJournal {
        let journal = try await BatchRenamer.apply(plan, progress: progress)
        registerUndo(of: journal)
        reloadLists()
        return journal
    }

    private func registerUndo(of journal: RenameJournal) {
        coordinator.undoManager.registerUndo(withTarget: coordinator) { [self] _ in
            MainActor.assumeIsolated { reverse(journal) }
        }
        coordinator.undoManager.setActionName(L10n.t("undo.batchRename"))
    }

    /// Undo and redo are the same move. Registered before the outcome is known, as UndoManager requires while undoing;
    /// when the reversal fails, the inverse has nothing to do.
    private func reverse(_ journal: RenameJournal) {
        let outcome = Outcome()
        coordinator.undoManager.registerUndo(withTarget: coordinator) { [self] _ in
            MainActor.assumeIsolated {
                if let inverse = outcome.journal { reverse(inverse) } else { NSSound.beep() }
            }
        }
        coordinator.undoManager.setActionName(L10n.t("undo.batchRename"))
        lastReversal = Task {
            do {
                outcome.journal = try await BatchRenamer.undo(journal)
            } catch {
                ToolUI.showError(error.localizedDescription, in: coordinator.grid?.view.window)
            }
            reloadLists()
        }
    }

    private func reloadLists() {
        coordinator.grid?.visiblePanes.forEach { $0.reloadActiveList() }
    }

    @MainActor private final class Outcome {
        var journal: RenameJournal?
    }
}
