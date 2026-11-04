import Foundation
import NSpaceContracts

/// Construction factory + entry point (Axiom 2: no global state, dependencies are constructor-injected)
public actor DirectoryReader: DirectoryReading {
    private var generation: UInt64 = 0

    public init() {}

    public func load(_ request: ReadRequest) async throws -> DirectorySnapshot {
        generation += 1
        let gen = generation
        var items = try scanDirectory(request)
        sortItems(&items, by: request.sort)
        try Task.checkCancellation()
        return DirectorySnapshot(directory: request.directory, generation: gen, items: items)
    }
}
