import Foundation
import NSpaceContracts

/// Local operations node (rename / newFolder / newFile / trash). Zero-argument construction injection (Axiom 2: no global mutable state).
public struct LocalOpsNode: OperationNode {
    public init() {}

    public func execute(_ spec: OperationSpec, context: NodeContext) async throws -> OperationReceipt {
        let started = Date()
        switch spec.kind {
        case .rename:
            return try renameEntry(spec, context: context, started: started)
        case .newFolder:
            return try createEntry(spec, context: context, isDirectory: true,
                                   defaultBase: "untitled folder", started: started)
        case .newFile:
            return try createEntry(spec, context: context, isDirectory: false,
                                   defaultBase: "untitled", started: started)
        case .trash:
            return try trashEntries(spec, context: context, started: started)
        default:
            throw LocalOpsError(.logic, "LocalOpsNode does not handle\(spec.kind.rawValue)")
        }
    }
}
