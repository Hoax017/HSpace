import Testing
import HSpaceTestSupport
import Foundation
@testable import Frecency

@Suite struct FrecencyRankingTests {

    // MARK: frecency decay

    @Test func freshScoreEqualsCount() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let e = FrecencyEntry(count: 5, lastAccess: now)
        #expect(SearchRanking.frecencyScore(e, now: now) == 5)
    }

    @Test func halfLifeHalvesScore() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let past = now.addingTimeInterval(-30 * 86_400)   // 30 days ago
        let e = FrecencyEntry(count: 4, lastAccess: past)
        let s = SearchRanking.frecencyScore(e, now: now, halfLifeDays: 30)
        #expect(abs(s - 2.0) < 0.001)   // 4 × 0.5^1 = 2
    }

    @Test func recentBeatsFrequentButOld() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let oftenButOld = FrecencyEntry(count: 50, lastAccess: now.addingTimeInterval(-365 * 86_400))
        let onceButToday = FrecencyEntry(count: 1, lastAccess: now)
        #expect(SearchRanking.frecencyScore(onceButToday, now: now)
                > SearchRanking.frecencyScore(oftenButOld, now: now))
    }

    // MARK: Match quality tiers

    @Test func matchTierOrdering() {
        let exact = SearchRanking.matchScore(query: "report", name: "report", path: "/a/report")!
        let prefix = SearchRanking.matchScore(query: "rep", name: "report.pdf", path: "/a/report.pdf")!
        let wordStart = SearchRanking.matchScore(query: "budget", name: "2026 budget.xlsx", path: "/a/2026 budget.xlsx")!
        let substr = SearchRanking.matchScore(query: "udg", name: "budget.xlsx", path: "/a/budget.xlsx")!
        let pathOnly = SearchRanking.matchScore(query: "docs", name: "report.pdf", path: "/docs/report.pdf")!
        #expect(exact > prefix)
        #expect(prefix > wordStart)
        #expect(wordStart > substr)
        #expect(substr > pathOnly)
    }

    @Test func noMatchReturnsNil() {
        #expect(SearchRanking.matchScore(query: "zzzz", name: "report.pdf", path: "/a/report.pdf") == nil)
    }

    @Test func subsequenceAcronymMatches() {
        // "prfi8" matches "program files 86" (Listary-style abbreviation), but weaker than a real substring
        let acr = SearchRanking.matchScore(query: "prfi8", name: "program files 86", path: "/x/program files 86")
        #expect(acr != nil)
        let realSub = SearchRanking.matchScore(query: "files", name: "program files 86", path: "/x/program files 86")!
        #expect(realSub > acr!)
    }

    // MARK: Fusion: frecency dominates short queries / match dominates long queries

    @Test func shortQueryFrecencyDominates() {
        // With a short query (1 character, mediocre match), high frecency should lift it above high match / low frecency
        let lowMatchHighFrec = SearchRanking.fused(match: 400, frecency: 20, queryLen: 1)
        let highMatchNoFrec = SearchRanking.fused(match: 600, frecency: 0, queryLen: 1)
        #expect(lowMatchHighFrec > highMatchNoFrec)
    }

    @Test func longQueryMatchDominates() {
        // With a long query (precise input), the match quality gap should beat the frecency gap
        let bestMatchNoFrec = SearchRanking.fused(match: 800, frecency: 0, queryLen: 8)
        let poorMatchHighFrec = SearchRanking.fused(match: 200, frecency: 20, queryLen: 8)
        #expect(bestMatchNoFrec > poorMatchHighFrec)
    }
}

@Suite struct FrecencyStoreTests {
    func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("hspace-frecency-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func recordIncrementsAndScores() async {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = FrecencyStore(directory: dir)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let url = dir.appendingPathComponent("a.txt")
        await store.record(url, now: now)
        await store.record(url, now: now)
        let s = await store.score(forPath: url.standardizedFileURL.path, now: now)
        #expect(s == 2)   // twice at the same moment → count 2, no decay
        let miss = await store.score(forPath: "/nope", now: now)
        #expect(miss == 0)
    }

    @Test func persistenceRoundTrip() async {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let url = dir.appendingPathComponent("keep.txt")
        do {
            let store = FrecencyStore(directory: dir)
            await store.record(url, now: now)
            await store.record(url, now: now)
            await store.record(url, now: now)
        }
        // A new instance restores from disk
        let reopened = FrecencyStore(directory: dir)
        let s = await reopened.score(forPath: url.standardizedFileURL.path, now: now)
        #expect(s == 3)
    }

    @Test func pruneEvictsLowestWhenOverCapacity() async {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = FrecencyStore(directory: dir, maxEntries: 10)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        // One high-frequency "hot" path + many one-off cold paths → the hot path must survive going over the cap
        let hot = dir.appendingPathComponent("hot.txt")
        for _ in 0..<20 { await store.record(hot, now: now) }
        for i in 0..<30 { await store.record(dir.appendingPathComponent("cold-\(i).txt"), now: now) }
        let c = await store.count()
        #expect(c <= 10)
        #expect(await store.score(forPath: hot.standardizedFileURL.path, now: now) > 0)   // hot path not evicted
    }

    // MARK: Multi-term queries + case priority (user report)

    /// The ranking layer must use the same rule as the search layer: queries with spaces must score here too.
    /// Otherwise "the engine finds it, the ranking scores it 0 and sinks it": to the user it still looks unfound.
    @Test func multiTermQueryScoresInsteadOfReturningNil() {
        let s = SearchRanking.matchScore(query: "override md",
                                         name: "OVERRIDE.md", path: "/u/.claude/OVERRIDE.md")
        #expect(s != nil, "A query with spaces must produce a score, got nil")
        // In the whole-string matching era this was always nil: the name has no space, so it is neither substring nor subsequence
        #expect((s ?? 0) > 0)
    }

    /// Every term must match: one term that matches nothing voids the entry (consistent with the engine's AND semantics)
    @Test func multiTermRequiresEveryTermToMatch() {
        #expect(SearchRanking.matchScore(query: "override zzz",
                                         name: "OVERRIDE.md", path: "/u/OVERRIDE.md") == nil)
    }

    /// User request: "show case-matching results first, then those with the same characters but different case"
    @Test func caseExactRanksAboveCaseInsensitive() {
        let exactCase = SearchRanking.matchScore(query: "override",
                                                 name: "override.md", path: "/a/override.md")!
        let otherCase = SearchRanking.matchScore(query: "override",
                                                 name: "OVERRIDE.md", path: "/a/OVERRIDE.md")!
        #expect(exactCase > otherCase,
                "Case-matching hits should rank first: \(exactCase) vs \(otherCase)")
    }

    /// But the case bonus **must not cross tiers**: a weak match (name substring) must not beat a strong match (prefix hit)
    /// just because its case happens to agree. Bonus cap 50 < smallest tier gap 200; this pins that down.
    @Test func caseBonusNeverOutranksAStrongerMatchTier() {
        // Prefix tier (800), case differs
        let strongerWrongCase = SearchRanking.matchScore(query: "rep",
                                                         name: "REPORT.pdf", path: "/a/REPORT.pdf")!
        // Name substring tier (around 400), case fully matches
        let weakerExactCase = SearchRanking.matchScore(query: "port",
                                                       name: "report.pdf", path: "/a/report.pdf")!
        #expect(strongerWrongCase > weakerExactCase,
                "Tier must beat the case bonus: \(strongerWrongCase) vs \(weakerExactCase)")
    }
}

private func keptFiles(_ dir: URL, _ name: String) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("\(name).corrupt-") }
}

/// D1: a file that cannot be loaded is kept aside and reported, never overwritten.
@Suite struct FrecencyCorruptFileTests {
    let garbage = Data("{ not json".utf8)

    func corruptDirectory() throws -> (dir: URL, file: URL) {
        let dir = try FaultFixture.tempDir("hspace-fr")
        let file = dir.appendingPathComponent("frecency.json")
        try FaultFixture.write(garbage, to: file)
        return (dir, file)
    }

    @Test func corruptFileIsKeptAsideAndReported() async throws {
        let (dir, file) = try corruptDirectory()
        defer { FaultFixture.remove(dir) }
        let store = FrecencyStore(directory: dir)
        #expect(await store.count() == 0)
        let kept = try #require(try keptFiles(dir, "frecency.json").first)
        #expect(try Data(contentsOf: kept) == garbage)
        let problem = try #require(await store.takeProblem())
        #expect(problem.localizedDescription.contains(kept.lastPathComponent))
        #expect(await store.takeProblem() == nil, "reported once")

        await store.record(URL(fileURLWithPath: "/tmp/a"))
        #expect(try Data(contentsOf: kept) == garbage)
        #expect(try Data(contentsOf: file) != garbage)
    }

    @Test func fileThatCannotBeMovedBlocksWritesUntilItCan() async throws {
        let (dir, file) = try corruptDirectory()
        defer { FaultFixture.remove(dir) }
        let store = FrecencyStore(directory: dir)
        try await FaultFixture.withReadOnly(dir) { () async throws in
            await store.record(URL(fileURLWithPath: "/tmp/a"))
            #expect(await store.takeProblem() != nil)
            #expect(try Data(contentsOf: file) == garbage)
        }
        await store.record(URL(fileURLWithPath: "/tmp/b"))
        let kept = try #require(try keptFiles(dir, "frecency.json").first)
        #expect(try Data(contentsOf: kept) == garbage)
        #expect(await FrecencyStore(directory: dir).count() == 2)
    }

    @Test func missingFileIsNotAProblem() async throws {
        let dir = try FaultFixture.tempDir("hspace-fr")
        defer { FaultFixture.remove(dir) }
        let store = FrecencyStore(directory: dir)
        #expect(await store.count() == 0)
        #expect(await store.takeProblem() == nil)
    }
}
