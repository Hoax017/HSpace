import AppKit
import HiddenRules
import HSpaceContracts
import HSpaceTestSupport
import Testing
@testable import HSpaceApp

/// Serialized: the rules are app-wide
@MainActor @Suite(.serialized) struct HiddenItemsWiringTests {
    private func withRules(_ body: (URL) async throws -> Void) async throws {
        let dir = try FaultFixture.tempDir("hspace-hiddenwiring")
        let previous = HiddenItems.store
        HiddenItems.store = HiddenRuleStore(directory: dir.appendingPathComponent("support"))
        defer {
            HiddenItems.store = previous
            FaultFixture.remove(dir)
        }
        try await body(dir)
    }

    private func item(_ dir: URL, _ name: String, folder: Bool = false) -> FileItem {
        FileItem(url: dir.appendingPathComponent(name), name: name, isDirectory: folder, isPackage: false,
                 isSymlink: false, isHidden: false, size: nil, modified: nil, created: nil, contentTypeID: nil)
    }

    private func names(_ model: DirectoryViewModel) async -> [String] {
        for _ in 0..<300 where model.isLoading { try? await Task.sleep(for: .milliseconds(10)) }
        return model.items.map(\.name)
    }

    @Test func hideRulesFollowShowHiddenAndExcludeRulesDoNot() async throws {
        try await withRules { dir in
            try HiddenItems.save([HiddenRule(pattern: "*.qlog"), HiddenRule(pattern: "*.qtmp", effect: .exclude)])
            let items = [item(dir, "a.qlog"), item(dir, "b.qtmp"), item(dir, "c.txt")]
            #expect(HiddenItems.filter(items, includeHidden: false).map(\.name) == ["c.txt"])
            let shown = HiddenItems.filter(items, includeHidden: true)
            #expect(shown.map(\.name) == ["a.qlog", "c.txt"])
            #expect(shown[0].isHidden)
            #expect(!shown[1].isHidden)
        }
    }

    @Test func aPackageCountsAsAFile() async throws {
        try await withRules { dir in
            try HiddenItems.save([HiddenRule(pattern: "QThing.app", target: .files)])
            let package = FileItem(url: dir.appendingPathComponent("QThing.app"), name: "QThing.app", isDirectory: true, isPackage: true,
                                   isSymlink: false, isHidden: false, size: nil, modified: nil, created: nil, contentTypeID: nil)
            #expect(HiddenItems.filter([package], includeHidden: false).isEmpty)
        }
    }

    @Test func aListingLeavesOutWhatTheRulesHideAndSavingAppliesAtOnce() async throws {
        try await withRules { dir in
            try FaultFixture.write(to: dir.appendingPathComponent("list/keep.txt"))
            try FaultFixture.write(to: dir.appendingPathComponent("list/drop.qlog"))
            let folder = dir.appendingPathComponent("list")
            let model = DirectoryViewModel(directory: folder)
            defer { model.stopWatching() }
            model.reload()
            #expect(await names(model).sorted() == ["drop.qlog", "keep.txt"])

            try HiddenItems.save([HiddenRule(pattern: "*.qlog")])
            for _ in 0..<300 where model.items.count != 1 { try? await Task.sleep(for: .milliseconds(10)) }
            #expect(model.items.map(\.name) == ["keep.txt"])
        }
    }

    @Test func columnsListThroughTheSameFilter() async throws {
        try await withRules { dir in
            try HiddenItems.save([HiddenRule(pattern: "*.qlog")])
            let model = DirectoryViewModel(directory: dir)
            defer { model.stopWatching() }
            let arranged = model.arranged([item(dir, "a.qlog"), item(dir, "b")], metadata: [:], applyFilter: false)
            #expect(arranged.map(\.name) == ["b"])
        }
    }

    @Test func aFailedSaveDoesNotChangeWhatShows() async throws {
        try await withRules { dir in
            let support = dir.appendingPathComponent("support")
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            chmod(support.path, 0o555)
            #expect(throws: HiddenRuleError.self) { try HiddenItems.save([HiddenRule(pattern: "*")]) }
            chmod(support.path, 0o755)
            #expect(HiddenItems.filter([item(dir, "a")], includeHidden: false).count == 1)
        }
    }
}
