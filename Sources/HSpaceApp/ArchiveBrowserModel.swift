import ArchiveEngine
import Foundation
import HSpaceContracts

/// What the archive browser shows and takes out of one archive. Nothing here touches the archive,
/// and all that comes out goes to a private temporary folder first.
@MainActor
final class ArchiveBrowserModel {
    let archive: URL
    private let engine = ArchiveEngineNode()
    private(set) var root: ArchiveTreeNode?
    private(set) var itemCount = 0
    /// Temporary folders still on disk
    private var scratchFolders: Set<URL> = []

    init(archive: URL) {
        self.archive = archive
    }

    func load() async throws {
        let entries = try await engine.list(archive)
        itemCount = entries.count
        root = await Task.detached { archiveTree(entries) }.value
    }

    /// Takes `nodes` out of the archive. The caller owns the folder and hands it to `discard` when done.
    func stage(_ nodes: [ArchiveTreeNode]) async throws -> (scratch: URL, items: [URL]) {
        let scratch = try ArchiveEngineNode.makeScratchDirectory()
        scratchFolders.insert(scratch)
        do {
            let items = try await engine.extract(Self.topmost(nodes).map(\.entry), from: archive, into: scratch)
            return (scratch, items)
        } catch {
            discard(scratch)
            throw error
        }
    }

    /// A failure here leaves a file in the temporary folder, which holds no data of its own, so it only gets reported.
    func discard(_ scratch: URL) {
        scratchFolders.remove(scratch)
        do {
            try ArchiveEngineNode.discardScratchDirectory(scratch)
        } catch {
            ProblemAlert.show(error as? any ClassifiedError)
        }
    }

    func discardAll() {
        scratchFolders.forEach(discard)
    }

    /// A folder comes with what it holds, so selected items inside a selected folder are dropped.
    static func topmost(_ nodes: [ArchiveTreeNode]) -> [ArchiveTreeNode] {
        let folders = nodes.filter(\.isFolder).map { $0.entry.path + "/" }
        return nodes.filter { node in !folders.contains { node.entry.path.hasPrefix($0) } }
    }
}
