import AppKit
import HSpaceContracts
import FileMetadata

/// Undo of a restore is registered before its outcome is known, so the closure reads the outcome through this.
@MainActor
private final class MetadataRecord {
    var changes: [MetadataChange] = []
}

/// Metadata changes. Not kernel operations: they change no file's contents or location, and `OperationSpec` has no kind for them.
/// They keep the same promises: progress, cancel, undo, truthful failure reports.
extension FileOpsCoordinator {
    /// Applies an edit to the items, undoably.
    func applyMetadata(_ edit: MetadataEdit, to urls: [URL], actionName: String) {
        guard !urls.isEmpty else { return }
        runMetadata(title: actionName, count: urls.count) { progress in
            try await Engines.metadata.apply(edit, to: urls, progress: progress)
        } onChanged: { [weak self] changes in
            self?.registerMetadataUndo(changes, actionName: actionName)
        }
    }

    private func registerMetadataUndo(_ changes: [MetadataChange], actionName: String) {
        undoManager.registerUndo(withTarget: self) { coord in
            MainActor.assumeIsolated { coord.restoreMetadata(changes, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
    }

    /// Undo and redo. The opposite step must be registered here, while UndoManager is undoing, or it lands on the wrong stack.
    private func restoreMetadata(_ changes: [MetadataChange], actionName: String) {
        let record = MetadataRecord()
        undoManager.registerUndo(withTarget: self) { coord in
            MainActor.assumeIsolated { coord.restoreMetadata(record.changes, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
        runMetadata(title: actionName, count: changes.count) { progress in
            try await Engines.metadata.restore(changes, progress: progress)
        } onChanged: { record.changes = $0 }
    }

    /// Runs a batch and reports it. The progress sheet appears only if the batch lasts, so a quick tag change shows nothing.
    private func runMetadata(title: String, count: Int,
                             work: @escaping @Sendable (@escaping MetadataProgress) async throws -> MetadataBatchResult,
                             onChanged: @escaping @MainActor ([MetadataChange]) -> Void) {
        let window = grid?.view.window
        let sheet = BatchProgressSheet(title: title, total: count)
        let task = Task { () -> MetadataBatchResult in
            try await work { done, _ in
                Task { @MainActor in sheet.update(done: done) }
            }
        }
        sheet.onCancel = { task.cancel() }
        let reveal = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(400))
            sheet.show(in: window)
        }
        Task { @MainActor in
            let outcome = await task.result
            reveal.cancel()
            sheet.close()
            switch outcome {
            case .success(let result):
                if !result.changed.isEmpty { onChanged(result.changed) }
                if let first = result.failures.first {
                    Toast.show(L10n.f("toast.metadataPartial", result.changed.count, result.failures.count,
                                      first.message), in: window)
                }
            case .failure(is CancellationError):
                Toast.show(L10n.t("toast.metadataCancelled"), in: window)
            case .failure(let error):
                Toast.show(error.localizedDescription, in: window)
            }
            reloadLists()
        }
    }
}
