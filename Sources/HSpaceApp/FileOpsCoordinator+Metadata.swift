import AppKit
import HSpaceContracts
import FileMetadata

/// Undo of a restore is registered before its outcome is known, so the closure waits for the outcome through this.
/// A redo pressed while the undo still runs has to wait, or it would find nothing to put back.
@MainActor
private final class MetadataRecord {
    private var changes: [MetadataChange] = []
    private var isFinished = false
    private var waiters: [CheckedContinuation<[MetadataChange], Never>] = []

    func finish(_ changes: [MetadataChange]) {
        self.changes = changes
        isFinished = true
        waiters.forEach { $0.resume(returning: changes) }
        waiters = []
    }

    func settled() async -> [MetadataChange] {
        if isFinished { return changes }
        return await withCheckedContinuation { waiters.append($0) }
    }
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
            self?.pushComments(changes)
        }
    }

    private func registerMetadataUndo(_ changes: [MetadataChange], actionName: String) {
        undoManager.registerUndo(withTarget: self) { coord in
            MainActor.assumeIsolated {
                coord.restoreMetadata(count: changes.count, actionName: actionName) { changes }
            }
        }
        undoManager.setActionName(actionName)
    }

    /// Undo and redo. The opposite step must be registered here, while UndoManager is undoing, or it lands on the wrong stack.
    private func restoreMetadata(count: Int, actionName: String,
                                 changes: @escaping @MainActor @Sendable () async -> [MetadataChange]) {
        let record = MetadataRecord()
        undoManager.registerUndo(withTarget: self) { coord in
            MainActor.assumeIsolated {
                coord.restoreMetadata(count: count, actionName: actionName) { await record.settled() }
            }
        }
        undoManager.setActionName(actionName)
        runMetadata(title: actionName, count: count) { progress in
            let before = await changes()
            return try await Engines.metadata.restore(before, progress: progress)
        } onChanged: { [weak self] changes in
            self?.pushComments(changes)
        } onFinished: { changes in
            record.finish(changes)
        }
    }

    /// The comments are saved by now. If Finder cannot be told, only its Get Info is behind, so this warns and does not fail.
    private func pushComments(_ changes: [MetadataChange]) {
        let urls = changes.compactMap { change -> URL? in
            if case .comment = change.before { return change.url }
            return nil
        }
        guard !urls.isEmpty else { return }
        let window = grid?.view.window
        let pusher = finderComments
        Task { @MainActor in
            guard let problem = await Engines.metadata.pushComments(of: urls, using: pusher) else { return }
            Toast.show(L10n.f("toast.commentNotInFinder", problem.localizedDescription), in: window)
        }
    }

    /// Runs a batch and reports it. The progress sheet appears only if the batch lasts, so a quick tag change shows nothing.
    private func runMetadata(title: String, count: Int,
                             work: @escaping @Sendable (@escaping MetadataProgress) async throws -> MetadataBatchResult,
                             onChanged: @escaping @MainActor ([MetadataChange]) -> Void,
                             onFinished: @escaping @MainActor ([MetadataChange]) -> Void = { _ in }) {
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
            Formatters.forgetCustomIcons()
            onFinished((try? outcome.get())?.changed ?? [])     // A failed run changed nothing to restore
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
