import Foundation
import HSpaceTestSupport
import QuickLocations
import Testing

private let contains: QuickLocationList.Match = { query, name, path in
    name.lowercased().contains(query.lowercased()) ? 100 : (path.lowercased().contains(query.lowercased()) ? 10 : nil)
}

@Suite struct QuickLocationListTests {
    private func location(_ title: String, _ path: String, _ kind: QuickLocationKind = .bookmark, habit: Double = 0) -> QuickLocation {
        QuickLocation(kind: kind, title: title, path: path, habit: habit)
    }

    @Test func aFolderIsListedOnceUnderItsFirstKind() {
        let merged = QuickLocationList.merge([location("Work", "/w")], [location("w", "/w/", .recent), location("x", "/x", .recent)])
        #expect(merged.map(\.title) == ["Work", "x"])
        #expect(merged.map(\.kind) == [.bookmark, .recent])
    }

    @Test func topPathsKeepsTheMostUsed() {
        #expect(QuickLocationList.topPaths(["/a": 1, "/b": 9, "/c": 5], limit: 2) == ["/b", "/c"])
        #expect(QuickLocationList.topPaths(["/a": 1], limit: 0).isEmpty)
    }

    @Test func equalScoresDoNotShuffle() {
        #expect(QuickLocationList.topPaths(["/b": 1, "/a": 1, "/c": 1]) == ["/a", "/b", "/c"])
    }

    @Test func anEmptyQueryKeepsTheOrder() {
        let all = [location("B", "/b"), location("A", "/a")]
        #expect(QuickLocationList.filter(all, query: "   ", match: contains) == all)
    }

    @Test func aNameMatchBeatsAPathMatch() {
        let all = [location("Other", "/photos/other"), location("Photos", "/p")]
        #expect(QuickLocationList.filter(all, query: "photos", match: contains).map(\.title) == ["Photos", "Other"])
    }

    @Test func nothingMatchesGivesNothing() {
        #expect(QuickLocationList.filter([location("A", "/a")], query: "zzz", match: contains).isEmpty)
    }

    @Test func habitDecidesBetweenEqualMatches() {
        let all = [location("Work one", "/1", .recent, habit: 1), location("Work two", "/2", .recent, habit: 20)]
        #expect(QuickLocationList.filter(all, query: "work", match: contains).first?.path == "/2")
    }

    @Test func bookmarksStayAboveOnATie() {
        let all = [location("Work", "/a"), location("Work", "/b", .volume)]
        #expect(QuickLocationList.filter(all, query: "work", match: contains).map(\.path) == ["/a", "/b"])
    }

    @Test func typedPathsAreRecognised() {
        let home = URL(fileURLWithPath: "/Users/me")
        #expect(QuickLocationList.typedPath("/tmp/", home: home) == "/tmp")
        #expect(QuickLocationList.typedPath("~", home: home) == "/Users/me")
        #expect(QuickLocationList.typedPath("~/Work", home: home) == "/Users/me/Work")
        #expect(QuickLocationList.typedPath("  /a/../b ", home: home) == "/b")
        #expect(QuickLocationList.typedPath("work", home: home) == nil)
        #expect(QuickLocationList.typedPath("~other", home: home) == nil)
    }
}

@Suite struct QuickLocationDiskTests {
    @Test func onlyFoldersSurvive() async throws {
        let dir = try FaultFixture.tempDir("hspace-quick")
        defer { FaultFixture.remove(dir) }
        let folder = dir.appendingPathComponent("folder")
        let package = dir.appendingPathComponent("Thing.app")
        let file = dir.appendingPathComponent("file.txt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        try FaultFixture.write(to: file)
        let gone = dir.appendingPathComponent("gone").path
        let kept = await QuickLocationList.existingFolders([file.path, gone, folder.path, package.path])
        #expect(kept == [folder.path])
    }

    @Test func aFolderBehindNoPermissionIsLeftOut() async throws {
        let dir = try FaultFixture.tempDir("hspace-quick")
        defer { FaultFixture.remove(dir) }
        let inner = dir.appendingPathComponent("inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: false)
        let kept = try await FaultFixture.withUnreadable(dir) { await QuickLocationList.existingFolders([inner.path]) }
        #expect(kept.isEmpty)
    }

    @Test func automountedPathsAreNotTouched() async {
        #expect(await QuickLocationList.existingFolders(["/net/server/share", "/Network/Servers/x"]).isEmpty)
    }

    @Test func aCancelledCheckStops() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await QuickLocationList.existingFolders(["/"])
        }
        #expect(await task.value.isEmpty)
    }

    @Test func statusTellsTheThreeCasesApart() async throws {
        let dir = try FaultFixture.tempDir("hspace-quick")
        defer { FaultFixture.remove(dir) }
        let file = dir.appendingPathComponent("a.txt")
        try FaultFixture.write(to: file)
        #expect(await QuickLocationList.status(of: dir.path) == .folder)
        #expect(await QuickLocationList.status(of: file.path) == .file)
        #expect(await QuickLocationList.status(of: dir.appendingPathComponent("none").path) == .missing)
    }
}
