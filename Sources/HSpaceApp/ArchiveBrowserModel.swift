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
    /// One folder for all previews, so that going back to a file does not extract it again
    private var previewFolder: URL?
    private var previewed: [ArchiveEntry: URL] = [:]
    /// Finds the password, the first time something comes out of the archive
    var unlock: (@MainActor (URL) async throws -> ArchivePasswordDecision)?
    private var isUnlocked = false
    /// Lives as long as the window
    private var password: String?

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
        try await unlockIfNeeded()
        let scratch = try ArchiveEngineNode.makeScratchDirectory()
        scratchFolders.insert(scratch)
        do {
            let items = try await engine.extract(Self.topmost(nodes).map(\.entry), from: archive, into: scratch,
                                                 password: password)
            return (scratch, items)
        } catch {
            discard(scratch)
            throw error
        }
    }

    /// The files among `nodes`, ready for Quick Look, in the same order. Folders and links have no preview.
    func previewURLs(_ nodes: [ArchiveTreeNode]) async throws -> [URL] {
        let entries = nodes.map(\.entry).filter { $0.kind == .file && $0.isSafe }
        let missing = entries.filter { previewed[$0] == nil }
        if !missing.isEmpty {
            try await unlockIfNeeded()
            let folder = try previewFolder ?? makePreviewFolder()
            for result in try await engine.extractForPreview(missing, from: archive, into: folder, password: password) {
                previewed[result.entry] = result.url
            }
        }
        return entries.compactMap { previewed[$0] }
    }

    /// Cancelling the password dialog cancels the work that needed it
    private func unlockIfNeeded() async throws {
        guard !isUnlocked, let unlock else { return }
        switch try await unlock(archive) {
        case .notNeeded: break
        case .password(let password): self.password = password
        case .cancelled: throw CancellationError()
        }
        isUnlocked = true
    }

    private func makePreviewFolder() throws -> URL {
        let folder = try ArchiveEngineNode.makeScratchDirectory()
        scratchFolders.insert(folder)
        previewFolder = folder
        return folder
    }

    /// A failure here leaves a file in the temporary folder, which holds no data of its own, so it only gets reported.
    func discard(_ scratch: URL) {
        scratchFolders.remove(scratch)
        if scratch == previewFolder {
            previewFolder = nil
            previewed = [:]
        }
        do {
            try ArchiveEngineNode.discardScratchDirectory(scratch)
        } catch {
            ProblemAlert.show(error as? any ClassifiedError)
        }
    }

    func discardAll() {
        scratchFolders.forEach(discard)
        password = nil
        isUnlocked = false
    }

    /// A folder comes with what it holds, so selected items inside a selected folder are dropped.
    static func topmost(_ nodes: [ArchiveTreeNode]) -> [ArchiveTreeNode] {
        let folders = nodes.filter(\.isFolder).map { $0.entry.path + "/" }
        return nodes.filter { node in !folders.contains { node.entry.path.hasPrefix($0) } }
    }
}
