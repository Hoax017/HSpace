import Foundation
import HSpaceContracts
import HSpaceTestSupport
import Testing
import ViewStyles

@Suite struct ViewStyleStoreTests {
    private let list = ViewStyle(viewMode: 1, sortKey: "size", sortAscending: false, includeHidden: true)

    @Test func aRuleAppliesToItsFolderHoweverItIsSpelled() throws {
        let dir = try FaultFixture.tempDir("hspace-styles")
        defer { FaultFixture.remove(dir) }
        let store = ViewStyleStore(directory: dir)
        try store.setRule(FolderViewRule(style: list), for: "/a/b/")

        let resolved = try #require(store.rule(for: "/a/./b"))
        #expect(resolved.isExact)
        #expect(resolved.rule.style == list)
        #expect(store.rule(for: "/a") == nil)
    }

    @Test func subfoldersFollowOnlyWhenAsked() throws {
        let dir = try FaultFixture.tempDir("hspace-styles")
        defer { FaultFixture.remove(dir) }
        let store = ViewStyleStore(directory: dir)
        try store.setRule(FolderViewRule(style: list), for: "/a")
        #expect(store.rule(for: "/a/b") == nil)

        try store.setRule(FolderViewRule(style: list, includeSubfolders: true), for: "/a")
        let inherited = try #require(store.rule(for: "/a/b/c"))
        #expect(!inherited.isExact)
        #expect(inherited.folder == "/a")
    }

    @Test func theNearestRuleWins() throws {
        let dir = try FaultFixture.tempDir("hspace-styles")
        defer { FaultFixture.remove(dir) }
        let store = ViewStyleStore(directory: dir)
        try store.setRule(FolderViewRule(style: list, includeSubfolders: true), for: "/a")
        let near = ViewStyle(viewMode: 0)
        try store.setRule(FolderViewRule(style: near, includeSubfolders: true), for: "/a/b")
        #expect(store.rule(for: "/a/b/c")?.rule.style == near)
        #expect(store.rule(for: "/a/z")?.rule.style == list)
    }

    @Test func theRootCanHaveARule() throws {
        let dir = try FaultFixture.tempDir("hspace-styles")
        defer { FaultFixture.remove(dir) }
        let store = ViewStyleStore(directory: dir)
        try store.setRule(FolderViewRule(style: list, includeSubfolders: true), for: "/")
        #expect(store.rule(for: "/x/y")?.folder == "/")
        #expect(store.rule(for: "/")?.isExact == true)
    }

    @Test func everythingSurvivesARestart() throws {
        let dir = try FaultFixture.tempDir("hspace-styles")
        defer { FaultFixture.remove(dir) }
        let store = ViewStyleStore(directory: dir)
        try store.setRule(FolderViewRule(style: list), for: "/a")
        let saved = try store.saveStyle(named: "Photos", style: list)

        let again = ViewStyleStore(directory: dir)
        #expect(again.rule(for: "/a")?.rule.style == list)
        #expect(again.styles() == [saved])
    }

    @Test func removingARuleEndsIt() throws {
        let dir = try FaultFixture.tempDir("hspace-styles")
        defer { FaultFixture.remove(dir) }
        let store = ViewStyleStore(directory: dir)
        try store.setRule(FolderViewRule(style: list), for: "/a")
        try store.removeRule(for: "/a")
        #expect(store.rule(for: "/a") == nil)
        #expect(ViewStyleStore(directory: dir).folders().isEmpty)
    }

    @Test func namesMustBeUsableAndUnique() throws {
        let dir = try FaultFixture.tempDir("hspace-styles")
        defer { FaultFixture.remove(dir) }
        let store = ViewStyleStore(directory: dir)
        let first = try store.saveStyle(named: "  Photos ", style: list)
        #expect(first.name == "Photos")
        #expect(throws: ViewStyleError.self) { try store.saveStyle(named: "   ", style: list) }
        #expect(throws: ViewStyleError.self) { try store.saveStyle(named: "photos", style: list) }
        let second = try store.saveStyle(named: "Music", style: list)
        #expect(throws: ViewStyleError.self) { try store.renameStyle(second.id, to: "PHOTOS") }
        try store.renameStyle(first.id, to: "photos")
        #expect(store.styles().map(\.name) == ["photos", "Music"])
    }

    @Test func renamingAStyleThatIsGoneFails() throws {
        let dir = try FaultFixture.tempDir("hspace-styles")
        defer { FaultFixture.remove(dir) }
        let store = ViewStyleStore(directory: dir)
        #expect(throws: ViewStyleError.self) { try store.renameStyle(UUID(), to: "x") }
    }

    @Test func aFailedSaveChangesNothing() async throws {
        let dir = try FaultFixture.tempDir("hspace-styles")
        defer { FaultFixture.remove(dir) }
        let store = ViewStyleStore(directory: dir)
        try store.setRule(FolderViewRule(style: list), for: "/a")
        try await FaultFixture.withReadOnly(dir) {
            #expect(throws: ViewStyleError.self) { try store.setRule(FolderViewRule(style: list), for: "/b") }
        }
        #expect(store.rule(for: "/b") == nil)
        #expect(store.rule(for: "/a") != nil)
    }

    @Test func aDamagedFileIsKeptAndReported() throws {
        let dir = try FaultFixture.tempDir("hspace-styles")
        defer { FaultFixture.remove(dir) }
        try FaultFixture.write(Data("{nope".utf8), to: dir.appendingPathComponent("view-styles.json"))
        let store = ViewStyleStore(directory: dir)
        #expect(store.folders().isEmpty)
        #expect(store.takeProblem() != nil)
        #expect(store.takeProblem() == nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.contains { $0.contains("corrupt") })
        try store.setRule(FolderViewRule(style: list), for: "/a")
    }

    @Test func aDamagedFileThatCannotMoveBlocksWritesInsteadOfLosingIt() async throws {
        let dir = try FaultFixture.tempDir("hspace-styles")
        defer { FaultFixture.remove(dir) }
        let file = dir.appendingPathComponent("view-styles.json")
        try FaultFixture.write(Data("{nope".utf8), to: file)
        try await FaultFixture.withReadOnly(dir) {
            let store = ViewStyleStore(directory: dir)
            #expect(store.takeProblem() != nil)
            #expect(throws: ViewStyleError.self) { try store.setRule(FolderViewRule(style: list), for: "/a") }
        }
        #expect(try Data(contentsOf: file) == Data("{nope".utf8))
    }
}
