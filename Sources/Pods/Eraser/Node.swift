import Foundation
import HSpaceContracts

/// Permanent deletion node (`.delete`). Zero-argument construction injection (Axiom 2: no global mutable state).
///
/// Semantics: per-item fault tolerance (matching the trash behaviour fixed in v0.19.18: what was really deleted must be
/// reported truthfully, not lost with the first error); throws only when nothing was deleted.
/// Deletion is **not undoable**, so the receipt has no trashedItems, only filesDone and failures.
public struct EraserNode: OperationNode {
    public init() {}

    public func execute(_ spec: OperationSpec, context: NodeContext) async throws -> OperationReceipt {
        let started = Date()
        guard spec.kind == .delete else {
            throw EraserError(.logic, "EraserNode does not handle\(spec.kind.rawValue)")
        }
        guard !spec.sources.isEmpty else {
            throw EraserError(.logic, "delete requires at least one source")
        }
        // The fence must be given explicitly: permanent deletion requests without one are always refused, no guessing, no pass-through
        guard let fence = spec.destination else {
            throw EraserError(.logic, "delete requires a destination as its fence root (blast-radius guard)")
        }
        let outside = spec.sources.filter { !EraserLimits.isFenced($0, by: fence) }
        guard outside.isEmpty else {
            throw EraserError(.logic,
                "Refused to delete items outside the fence (\(outside.count) items, first: \(outside[0].lastPathComponent))")
        }

        let fm = FileManager.default
        context.report(.scanTotals(files: spec.sources.count, bytes: 0))
        var done = 0
        var failures: [OperationFailure] = []
        for src in spec.sources {
            if Task.isCancelled { throw CancellationError() }
            do {
                try fm.removeItem(at: src)
                done += 1
                context.report(.progress(filesDone: done, bytesDone: 0, currentPath: src.path))
            } catch {
                failures.append(OperationFailure(url: src, errorClass: .external,
                                                 message: "Could not permanently delete:\(error.localizedDescription)"))
            }
        }
        // Nothing deleted at all = a real failure
        if done == 0, let first = failures.first {
            throw EraserError(first.errorClass, first.message)
        }
        return OperationReceipt(id: context.operationID, filesDone: done, bytesDone: 0,
                                duration: Date().timeIntervalSince(started), failures: failures)
    }
}
