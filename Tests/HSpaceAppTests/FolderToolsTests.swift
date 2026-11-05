import BatchRename
import Foundation
import HSpaceContracts
import HSpaceKernel
import HSpaceTestSupport
import LocalOps
import Testing
import Transfer
@testable import HSpaceApp

/// Answers the conflict panel the same way every time, by kind of clash.
private struct FixedArbiter: ConflictArbiter {
    let folders: ConflictDecision
    let files: ConflictDecision

    func arbitrate(operation id: UUID, conflicts: [FileConflict]) async -> [URL: ConflictDecision]? {
        Dictionary(uniqueKeysWithValues: conflicts.map { ($0.source, $0.bothDirectories ? folders : files) })
    }
}

private struct CancellingArbiter: ConflictArbiter {
    func arbitrate(operation id: UUID, conflicts: [FileConflict]) async -> [URL: ConflictDecision]? { nil }
}

/// Through the real kernel and Transfer: L17 stands on the merge rules fixed in A8.
@MainActor @Suite struct FolderToolsTests {
    private func tools(arbiter: any ConflictArbiter) async -> (FolderTools, Discarded) {
        let kernel = OperationKernel()
        await kernel.register(TransferNode(), for: [.copy, .move, .duplicate])
        await kernel.register(LocalOpsNode(), for: [.rename, .newFolder, .newFile, .trash])
        await kernel.setArbiter(arbiter)
        let coordinator = FileOpsCoordinator(kernel: kernel, grid: PaneGridController(initialDirectory: URL(fileURLWithPath: "/")))
        let tools = FolderTools(coordinator: coordinator)
        let discarded = Discarded()
        tools.discard = { discarded.urls += $0 }
        return (tools, discarded)
    }

    private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    private func write(_ text: String, _ url: URL) throws { try FaultFixture.write(Data(text.utf8), to: url) }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @Test func mergeFollowsTheTransferRules() async throws {
        let dir = try FaultFixture.tempDir("hspace-folder-tools").resolvingSymlinksInPath()
        defer { FaultFixture.remove(dir) }
        let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b")
        try write("old", a.appendingPathComponent("sub/same"))
        try write("keep", a.appendingPathComponent("sub/only-a"))
        try write("new", b.appendingPathComponent("sub/same"))
        try write("added", b.appendingPathComponent("sub/only-b"))
        try write("file", b.appendingPathComponent("sub/clash"))
        try write("inner", a.appendingPathComponent("sub/clash/inner"))
        try write("plain", b.appendingPathComponent("plain"))

        let (tools, discarded) = await tools(arbiter: FixedArbiter(folders: .mergeFolders, files: .replace))
        let finished = await tools.run(try FolderPlanner.mergePlan(folders: [a, b], into: a))

        #expect(finished)
        let sub = a.appendingPathComponent("sub")
        #expect(try text(sub.appendingPathComponent("same")) == "new")        // File over file replaces
        #expect(try text(sub.appendingPathComponent("only-a")) == "keep")
        #expect(try text(sub.appendingPathComponent("only-b")) == "added")
        #expect(try text(sub.appendingPathComponent("clash/inner")) == "inner")   // File and folder are both kept
        #expect(try text(sub.appendingPathComponent("clash 2")) == "file")
        #expect(try text(a.appendingPathComponent("plain")) == "plain")
        #expect(discarded.urls == [b])
    }

    @Test func aSkippedClashKeepsItsFolderOutOfTheTrash() async throws {
        let dir = try FaultFixture.tempDir("hspace-folder-tools").resolvingSymlinksInPath()
        defer { FaultFixture.remove(dir) }
        let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b")
        try write("a", a.appendingPathComponent("same"))
        try write("b", b.appendingPathComponent("same"))
        try write("x", b.appendingPathComponent("other"))
        let (tools, discarded) = await tools(arbiter: FixedArbiter(folders: .skip, files: .skip))
        await tools.run(try FolderPlanner.mergePlan(folders: [a, b], into: a))
        #expect(try text(a.appendingPathComponent("same")) == "a")
        #expect(try text(b.appendingPathComponent("same")) == "b")
        #expect(exists(a.appendingPathComponent("other")))
        #expect(discarded.urls.isEmpty)
    }

    @Test func cancellingTheConflictPanelDiscardsNothing() async throws {
        let dir = try FaultFixture.tempDir("hspace-folder-tools").resolvingSymlinksInPath()
        defer { FaultFixture.remove(dir) }
        let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b")
        try write("a", a.appendingPathComponent("same"))
        try write("b", b.appendingPathComponent("same"))
        let (tools, discarded) = await tools(arbiter: CancellingArbiter())
        let finished = await tools.run(try FolderPlanner.mergePlan(folders: [a, b], into: a))
        #expect(!finished)
        #expect(discarded.urls.isEmpty)
        #expect(try text(b.appendingPathComponent("same")) == "b")
    }

    @Test func flattenBringsFilesUpAndKeepsSameNamedOnesApart() async throws {
        let dir = try FaultFixture.tempDir("hspace-folder-tools").resolvingSymlinksInPath()
        defer { FaultFixture.remove(dir) }
        let top = dir.appendingPathComponent("top")
        try write("1", top.appendingPathComponent("x/note"))
        try write("2", top.appendingPathComponent("y/deep/note"))
        try write("3", top.appendingPathComponent("y/other"))
        let (tools, discarded) = await tools(arbiter: FixedArbiter(folders: .skip, files: .skip))
        await tools.run(try FolderPlanner.flattenPlan(folder: top))
        #expect(try text(top.appendingPathComponent("note")) == "1")
        #expect(try text(top.appendingPathComponent("note 2")) == "2")
        #expect(try text(top.appendingPathComponent("other")) == "3")
        #expect(Set(discarded.urls.map(\.lastPathComponent)) == ["x", "y"])
    }

    @Test func aFolderWithOnlyEmptySubfoldersFlattensWithoutAMove() async throws {
        let dir = try FaultFixture.tempDir("hspace-folder-tools").resolvingSymlinksInPath()
        defer { FaultFixture.remove(dir) }
        let top = dir.appendingPathComponent("top")
        try FileManager.default.createDirectory(at: top.appendingPathComponent("empty"), withIntermediateDirectories: true)
        let (tools, discarded) = await tools(arbiter: FixedArbiter(folders: .skip, files: .skip))
        let finished = await tools.run(try FolderPlanner.flattenPlan(folder: top))
        #expect(finished)
        #expect(discarded.urls.map(\.lastPathComponent) == ["empty"])
    }

    @Test func aFailedMoveDiscardsNothing() async throws {
        let dir = try FaultFixture.tempDir("hspace-folder-tools").resolvingSymlinksInPath()
        defer { FaultFixture.remove(dir) }
        let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try write("x", b.appendingPathComponent("file"))
        let (tools, discarded) = await tools(arbiter: FixedArbiter(folders: .skip, files: .skip))
        let plan = try FolderPlanner.mergePlan(folders: [a, b], into: a)
        chmod(a.path, 0o555)
        let finished = await tools.run(plan)
        chmod(a.path, 0o755)
        #expect(!finished)
        #expect(discarded.urls.isEmpty)
        #expect(exists(b.appendingPathComponent("file")))
    }
}

@MainActor private final class Discarded {
    var urls: [URL] = []
}
