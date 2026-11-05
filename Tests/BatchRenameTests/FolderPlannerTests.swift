import BatchRename
import Foundation
import HSpaceTestSupport
import Testing

@Suite struct FolderPlannerTests {
    private func tree(_ paths: [String]) throws -> URL {
        let dir = try FaultFixture.tempDir("hspace-folders").resolvingSymlinksInPath()
        for path in paths {
            let url = dir.appendingPathComponent(path)
            if path.hasSuffix("/") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try FaultFixture.write(to: url)
            }
        }
        return dir
    }

    private func relative(_ urls: [URL], to dir: URL) -> [String] {
        urls.map { String($0.resolvingSymlinksInPath().path.dropFirst(dir.path.count + 1)) }
    }

    @Test func mergeMovesTheChildrenOfTheOthers() throws {
        let dir = try tree(["a/1", "b/2", "b/sub/3", "c/.hidden", "b/.DS_Store"])
        defer { FaultFixture.remove(dir) }
        let folders = ["a", "b", "c"].map { dir.appendingPathComponent($0) }
        let plan = try FolderPlanner.mergePlan(folders: folders, into: folders[0])
        #expect(relative(plan.moves, to: dir) == ["b/2", "b/sub", "c/.hidden"])
        #expect(relative(plan.emptied, to: dir) == ["b", "c"])
    }

    @Test func aFolderHoldingTheTargetCannotBeMergedIntoIt() throws {
        let dir = try tree(["a/b/file"])
        defer { FaultFixture.remove(dir) }
        let outer = dir.appendingPathComponent("a"), inner = outer.appendingPathComponent("b")
        #expect(throws: BatchRenameError.self) { try FolderPlanner.mergePlan(folders: [outer, inner], into: inner) }
        let plan = try FolderPlanner.mergePlan(folders: [outer, inner], into: outer)
        #expect(relative(plan.moves, to: dir) == ["a/b/file"])
    }

    @Test func mergeRefusesWhatIsNotAFolder() throws {
        let dir = try tree(["a/", "file"])
        defer { FaultFixture.remove(dir) }
        let folder = dir.appendingPathComponent("a"), file = dir.appendingPathComponent("file")
        #expect(throws: BatchRenameError.self) { try FolderPlanner.mergePlan(folders: [folder, file], into: folder) }
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        #expect(throws: BatchRenameError.self) { try FolderPlanner.mergePlan(folders: [folder, link], into: link) }
    }

    @Test func flattenTakesFilesFromEveryLevelAndLeavesTheTopAlone() throws {
        let dir = try tree(["top", "x/1", "x/y/2", "x/y/z/3", "w/4", "w/.DS_Store", "empty/"])
        defer { FaultFixture.remove(dir) }
        let plan = try FolderPlanner.flattenPlan(folder: dir)
        #expect(relative(plan.moves, to: dir) == ["w/4", "x/1", "x/y/2", "x/y/z/3"])
        #expect(relative(plan.emptied, to: dir) == ["empty", "w", "x"])
    }

    @Test func flattenKeepsPackagesHiddenFoldersAndLinksWhole() throws {
        let dir = try tree(["x/App.app/Contents/binary", "x/.git/config", ".git/config"])
        defer { FaultFixture.remove(dir) }
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("x/link"),
                                                   withDestinationURL: dir.appendingPathComponent(".git"))
        let plan = try FolderPlanner.flattenPlan(folder: dir)
        #expect(plan.moves.map(\.lastPathComponent).sorted() == [".git", "App.app", "link"])
        #expect(relative(plan.emptied, to: dir) == ["x"])
    }

    @Test func anUnreadableFolderStopsThePlan() async throws {
        let dir = try tree(["x/locked/file", "x/other"])
        defer { FaultFixture.remove(dir) }
        try await FaultFixture.withUnreadable(dir.appendingPathComponent("x/locked")) {
            #expect(throws: BatchRenameError.self) { try FolderPlanner.flattenPlan(folder: dir) }
            #expect(throws: BatchRenameError.self) { try FolderPlanner.isEmptied(dir.appendingPathComponent("x")) }
        }
    }

    @Test func aFolderIsEmptiedOnlyWhenNothingStayedBehind() throws {
        let dir = try tree(["empty/sub/", "empty/.DS_Store", "kept/sub/file", "dotted/.hidden/file"])
        defer { FaultFixture.remove(dir) }
        #expect(try FolderPlanner.isEmptied(dir.appendingPathComponent("empty")))
        #expect(try !FolderPlanner.isEmptied(dir.appendingPathComponent("kept")))
        #expect(try !FolderPlanner.isEmptied(dir.appendingPathComponent("dotted")))
    }
}
