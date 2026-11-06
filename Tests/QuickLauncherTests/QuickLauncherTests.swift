import Foundation
import HSpaceTestSupport
import QuickLauncher
import Testing

private let contains: LauncherRanking.Match = { query, title, detail in
    title.lowercased().contains(query.lowercased()) ? 100 : (detail.lowercased().contains(query.lowercased()) ? 10 : nil)
}

private func command(_ id: String, _ title: String? = nil) -> LauncherEntry {
    LauncherEntry(id: id, kind: .command, title: title ?? id, detail: "Menu")
}

private func location(_ id: String) -> LauncherEntry {
    LauncherEntry(id: id, kind: .location, title: id, detail: "/\(id)")
}

@Suite struct LauncherQueryTests {
    @Test func aChevronNarrowsToCommands() {
        #expect(LauncherQuery("> copy") == LauncherQuery(">copy"))
        #expect(LauncherQuery("> copy").commandsOnly)
        #expect(LauncherQuery("> copy").text == "copy")
        #expect(!LauncherQuery(" copy ").commandsOnly)
        #expect(LauncherQuery(" copy ").text == "copy")
    }
}

@Suite struct LauncherRankingTests {
    @Test func anEmptyQueryPutsRecentCommandsFirst() {
        let all = [command("a"), command("b"), location("c")]
        let ranked = LauncherRanking.rank(all, query: LauncherQuery(""), recent: ["b"], match: contains)
        #expect(ranked.map(\.id) == ["b", "a", "c"])
    }

    @Test func commandsOnlyHidesLocations() {
        let all = [location("copy"), command("copy command")]
        #expect(LauncherRanking.rank(all, query: LauncherQuery(">copy"), recent: [], match: contains).map(\.kind) == [.command])
        #expect(LauncherRanking.rank(all, query: LauncherQuery(">"), recent: [], match: contains).map(\.kind) == [.command])
    }

    @Test func aBetterMatchWins() {
        let all = [command("x", "Other"), command("y", "Copy")]
        #expect(LauncherRanking.rank(all, query: LauncherQuery("menu"), recent: [], match: contains).count == 2)
        #expect(LauncherRanking.rank(all, query: LauncherQuery("copy"), recent: [], match: contains).map(\.id) == ["y"])
    }

    @Test func recentUseDecidesEqualMatchesOnly() {
        let all = [command("a", "Copy one"), command("b", "Copy two")]
        #expect(LauncherRanking.rank(all, query: LauncherQuery("copy"), recent: ["b"], match: contains).first?.id == "b")
        let scored: LauncherRanking.Match = { _, title, _ in title == "Copy one" ? 800 : 400 }
        #expect(LauncherRanking.rank(all, query: LauncherQuery("copy"), recent: ["b"], match: scored).first?.id == "a")
    }

    @Test func nothingMatchingGivesNothing() {
        #expect(LauncherRanking.rank([command("a")], query: LauncherQuery("zzz"), recent: [], match: contains).isEmpty)
    }

    @Test func historyOfVanishedCommandsIsIgnored() {
        #expect(LauncherRanking.rank([command("a")], query: LauncherQuery(""), recent: ["gone"], match: contains).map(\.id) == ["a"])
    }

    @Test func aRepeatInTheHistoryDoesNotBreakRanking() {
        #expect(LauncherRanking.rank([command("a")], query: LauncherQuery("a"), recent: ["a", "a"], match: contains).map(\.id) == ["a"])
    }

    @Test func theListIsCapped() {
        let many = (0..<200).map { command("copy\($0)") }
        #expect(LauncherRanking.rank(many, query: LauncherQuery("copy"), recent: [], match: contains).count == LauncherRanking.limit)
        #expect(LauncherRanking.rank(many, query: LauncherQuery(""), recent: [], match: contains).count == LauncherRanking.limit)
    }
}

@Suite struct CommandHistoryStoreTests {
    @Test func theLatestComesFirstWithoutRepeats() throws {
        let dir = try FaultFixture.tempDir("hspace-launcher")
        defer { FaultFixture.remove(dir) }
        let store = CommandHistoryStore(directory: dir)
        try store.record("a")
        try store.record("b")
        try store.record("a")
        #expect(store.recent() == ["a", "b"])
        #expect(CommandHistoryStore(directory: dir).recent() == ["a", "b"])
    }

    @Test func itKeepsOnlyTheLatest() throws {
        let dir = try FaultFixture.tempDir("hspace-launcher")
        defer { FaultFixture.remove(dir) }
        let store = CommandHistoryStore(directory: dir, capacity: 2)
        for id in ["a", "b", "c"] { try store.record(id) }
        #expect(store.recent() == ["c", "b"])
    }

    @Test func aFailedWriteChangesNothing() async throws {
        let dir = try FaultFixture.tempDir("hspace-launcher")
        defer { FaultFixture.remove(dir) }
        let store = CommandHistoryStore(directory: dir)
        try store.record("a")
        try await FaultFixture.withReadOnly(dir) {
            #expect(throws: LauncherError.self) { try store.record("b") }
        }
        #expect(store.recent() == ["a"])
    }

    @Test func aDamagedFileIsKeptAndReported() throws {
        let dir = try FaultFixture.tempDir("hspace-launcher")
        defer { FaultFixture.remove(dir) }
        try FaultFixture.write(Data("nope".utf8), to: dir.appendingPathComponent("launcher-history.json"))
        let store = CommandHistoryStore(directory: dir)
        #expect(store.recent().isEmpty)
        #expect(store.takeProblem() != nil)
        #expect(store.takeProblem() == nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.contains { $0.contains("corrupt") })
    }

    @Test func aDamagedFileThatCannotMoveIsNeverOverwritten() async throws {
        let dir = try FaultFixture.tempDir("hspace-launcher")
        defer { FaultFixture.remove(dir) }
        let file = dir.appendingPathComponent("launcher-history.json")
        try FaultFixture.write(Data("nope".utf8), to: file)
        try await FaultFixture.withReadOnly(dir) {
            let store = CommandHistoryStore(directory: dir)
            #expect(throws: LauncherError.self) { try store.record("a") }
        }
        #expect(try Data(contentsOf: file) == Data("nope".utf8))
    }
}
