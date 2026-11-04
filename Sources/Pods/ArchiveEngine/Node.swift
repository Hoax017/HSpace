import Foundation
import HSpaceContracts

/// Archive node (compress / extract). Zero-argument construction injection (Axiom 2: no global mutable state).
public struct ArchiveEngineNode: OperationNode {
    public init() {}

    public func execute(_ spec: OperationSpec, context: NodeContext) async throws -> OperationReceipt {
        let started = Date()
        switch spec.kind {
        case .compress:
            return try await compress(spec, context: context, started: started)
        case .extract:
            return try await extract(spec, context: context, started: started)
        default:
            throw ArchiveError(.logic, "ArchiveEngineNode does not handle\(spec.kind.rawValue)")
        }
    }
}
