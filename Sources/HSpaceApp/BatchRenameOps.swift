import AppKit
import BatchRename

/// Runs rename batches for one window and puts each on that window's undo stack as a single action.
/// The rename engine is the BatchRename pod: a batch has to be all or nothing, which no per-item kernel operation can promise.
@MainActor
final class BatchRenameOps {
    private let coordinator: FileOpsCoordinator
    private let store: RenameStore?
    /// The latest undo or redo: UndoManager cannot wait for async work, tests can
    private(set) var lastReversal: Task<Void, Never>?
    /// How a refused undo reaches the user. Replaced in tests, which have no window for an alert.
    var report: (String) -> Void

    init(coordinator: FileOpsCoordinator, store: RenameStore?) {
        self.coordinator = coordinator
        self.store = store
        report = { [weak coordinator] in ToolUI.showError($0, in: coordinator?.grid?.view.window) }
    }

    /// Applies a plan. Throws what the pod throws; nothing is registered unless the batch landed.
    func apply(_ plan: RenamePlan, progress: @escaping @Sendable (Int, Int) -> Void) async throws -> RenameJournal {
        let journal = try await BatchRenamer.apply(plan, progress: progress)
        registerUndo(of: journal)
        await log(journal, reverses: nil)
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
                let inverse = try await BatchRenamer.undo(journal)
                outcome.journal = inverse
                await log(inverse, reverses: journal.id)
            } catch {
                report(error.localizedDescription)
            }
            reloadLists()
        }
    }

    /// Undo from the log. It lands on the undo stack like any other batch, so ⌘Z takes it back.
    func undo(_ entry: RenameLogEntry) async {
        reverse(entry.journal)
        await lastReversal?.value
    }

    private func log(_ journal: RenameJournal, reverses: UUID?) async {
        guard let store else { return }
        await store.record(journal, reverses: reverses)
        ProblemAlert.show(await store.takeProblem())
    }

    private func reloadLists() {
        coordinator.grid?.visiblePanes.forEach { $0.reloadActiveList() }
    }

    @MainActor private final class Outcome {
        var journal: RenameJournal?
    }
}
