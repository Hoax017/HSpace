import Foundation
import HSpaceContracts

/// Archive node (compress / extract). Zero-argument construction injection (Axiom 2: no global mutable state).
public struct ArchiveEngineNode: OperationNode {
    /// Read when an archive is made, so a changed setting applies to the next one
    let compression: @Sendable () -> ArchiveCompression

    public init(compression: @escaping @Sendable () -> ArchiveCompression = { .normal }) {
        self.compression = compression
    }

    public func execute(_ spec: OperationSpec, context: NodeContext) async throws -> OperationReceipt {
        let started = Date()
        if let options = spec.archiveOptions, let password = options.password, !password.isEmpty {
            try Self.checkPassword(password)
            // tar.gz has no encryption, and only zip can be read with a password
            let isZip = spec.kind == .compress
                ? options.format.lowercased() != "tar.gz"
                : spec.sources.allSatisfy { ArchiveFormat.detect($0) == .zip }
            guard isZip else {
                throw ArchiveError(.logic, "This archive format cannot use a password")
            }
        }
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
