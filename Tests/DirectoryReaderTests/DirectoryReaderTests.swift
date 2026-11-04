import Testing
import Foundation
@testable import DirectoryReader
import HSpaceContracts

/// Black-box acceptance: only through the Contract public surface, asserting on real temp fixture trees (no fakes or mocks)
@Suite struct DirectoryReaderTests {
    /// Builds the fixture tree: a.txt (5B) / B.txt (10B) / sub/ / .secret
    func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hspace-dr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("helloworld".utf8).write(to: root.appendingPathComponent("B.txt"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"),
                                                withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent(".secret"))
        return root
    }

    @Test func defaultLoadFiltersHiddenAndSortsFoldersFirst() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let snap = try await DirectoryReader().load(ReadRequest(directory: root))
        #expect(snap.items.map(\.name) == ["sub", "a.txt", "B.txt"])
        #expect(snap.items[0].isDirectory)
        #expect(snap.items[1].size == 5)
    }

    @Test func includeHiddenShowsDotfiles() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let snap = try await DirectoryReader().load(ReadRequest(directory: root, includeHidden: true))
        #expect(snap.items.contains { $0.name == ".secret" })
        #expect(snap.items.count == 4)
    }

    @Test func sortBySizeDescending() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sort = SortSpec(key: .size, ascending: false, foldersFirst: false)
        let snap = try await DirectoryReader().load(ReadRequest(directory: root, sort: sort))
        #expect(snap.items.first?.name == "B.txt")  // 10B is the largest
    }

    @Test func generationIsMonotonic() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = DirectoryReader()
        let s1 = try await reader.load(ReadRequest(directory: root))
        let s2 = try await reader.load(ReadRequest(directory: root))
        #expect(s2.generation > s1.generation)
    }

    @Test func missingDirectoryThrowsClassifiedError() async {
        let bogus = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        do {
            _ = try await DirectoryReader().load(ReadRequest(directory: bogus))
            Issue.record("Expected an error")
        } catch let e as any ClassifiedError {
            #expect(e.errorClass == .external || e.errorClass == .transient)
        } catch {
            Issue.record("Unclassified error (violates P6.4):\(error)")
        }
    }

    /// I-26: new sort keys created/added: strict weak ordering + nil values (distantPast) do not crash and sort first
    @Test func sortByAddedAndCreated() {
        let now = Date()
        func item(_ n: String, created: Date?, added: Date?) -> FileItem {
            FileItem(url: URL(fileURLWithPath: "/tmp/\(n)"), name: n, isDirectory: false,
                     isPackage: false, isSymlink: false, isHidden: false, size: 1,
                     modified: now, created: created, added: added, contentTypeID: "public.data")
        }
        var items = [item("b", created: now, added: now.addingTimeInterval(-100)),
                     item("a", created: now.addingTimeInterval(-50), added: now),
                     item("c", created: nil, added: nil)]
        sortItems(&items, by: SortSpec(key: .added, ascending: false, foldersFirst: false))
        #expect(items.map(\.name) == ["a", "b", "c"])
        sortItems(&items, by: SortSpec(key: .created, ascending: true, foldersFirst: false))
        #expect(items.map(\.name) == ["c", "a", "b"])
    }

    /// I-26 full key coverage: name/dateModified/kind in both directions (size/created/added have dedicated tests)
    @Test func sortByNameDateKindBothDirections() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        func item(_ n: String, m: TimeInterval, kind: String) -> FileItem {
            FileItem(url: URL(fileURLWithPath: "/tmp/\(n)"), name: n, isDirectory: false,
                     isPackage: false, isSymlink: false, isHidden: false, size: 1,
                     modified: t0.addingTimeInterval(m), created: t0, added: t0, contentTypeID: kind)
        }
        var items = [item("b", m: 30, kind: "public.png"),
                     item("a", m: 10, kind: "public.zip"),
                     item("c", m: 20, kind: "public.jpeg")]
        sortItems(&items, by: SortSpec(key: .name, ascending: true, foldersFirst: false))
        #expect(items.map(\.name) == ["a", "b", "c"])
        sortItems(&items, by: SortSpec(key: .name, ascending: false, foldersFirst: false))
        #expect(items.map(\.name) == ["c", "b", "a"])
        sortItems(&items, by: SortSpec(key: .dateModified, ascending: true, foldersFirst: false))
        #expect(items.map(\.name) == ["a", "c", "b"])
        sortItems(&items, by: SortSpec(key: .dateModified, ascending: false, foldersFirst: false))
        #expect(items.map(\.name) == ["b", "c", "a"])
        sortItems(&items, by: SortSpec(key: .kind, ascending: true, foldersFirst: false))
        #expect(items.map(\.name) == ["c", "b", "a"])   // jpeg < png < zip
        sortItems(&items, by: SortSpec(key: .kind, ascending: false, foldersFirst: false))
        #expect(items.map(\.name) == ["a", "b", "c"])
    }

    /// I-50 Finder style: folders-first applies only to name sort; when sorting by time folders mix purely by time (no floating to the top).
    @Test func foldersFirstOnlyAppliesToNameSort() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        func node(_ n: String, dir: Bool, m: TimeInterval) -> FileItem {
            FileItem(url: URL(fileURLWithPath: "/tmp/\(n)"), name: n, isDirectory: dir,
                     isPackage: false, isSymlink: false, isHidden: false, size: dir ? nil : 1,
                     modified: t0.addingTimeInterval(m), created: t0, added: t0, contentTypeID: nil)
        }
        // Old folder + new file
        var items = [node("newfile.txt", dir: false, m: 100), node("oldfolder", dir: true, m: 10)]

        // By name + folders first → folder first (newfile sorts later by name, and the folder floats up)
        sortItems(&items, by: SortSpec(key: .name, ascending: true, foldersFirst: true))
        #expect(items.first?.name == "oldfolder")

        // By date modified descending + folders first → purely by time: new file first, old folder last (the folder no longer floats)
        sortItems(&items, by: SortSpec(key: .dateModified, ascending: false, foldersFirst: true))
        #expect(items.map(\.name) == ["newfile.txt", "oldfolder"])

        // By date modified ascending + folders first → old folder first (because it is older, not because of folders-first)
        sortItems(&items, by: SortSpec(key: .dateModified, ascending: true, foldersFirst: true))
        #expect(items.map(\.name) == ["oldfolder", "newfile.txt"])
    }
}
