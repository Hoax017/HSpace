import Testing
import Foundation
@testable import SearchEngine

/// Black-box acceptance: channel B (hidden file scan) asserts precisely on real temp fixture trees;
/// channel A (Spotlight) depends on system index state, so it only loosely asserts "starts and stops without crashing" (no fake mocks).
@MainActor
@Suite struct SearchEngineTests {
    /// Fixture tree: visible hit + dot-hidden hit + hit inside a hidden directory + deep hit + hit inside a heavy directory (should be skipped)
    func makeFixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nspace-search-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent(".hiddensub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        let files = [
            "visible-nsneedle.txt",
            ".hidden-nsneedle.txt",
            ".hiddensub/inside-nsneedle.txt",
            "sub/deep-nsneedle.txt",
            "node_modules/skip-nsneedle.txt",
            "unrelated.txt",
        ]
        for f in files {
            try Data("x".utf8).write(to: dir.appendingPathComponent(f))
        }
        return dir
    }

    /// Collects stream results until natural completion or timeout (timeout cancels = verifies cooperative stop)
    func collect(_ request: SearchRequest, timeout: Double = 5) async -> [SearchHit] {
        let engine = SearchEngine()
        let stream = engine.search(request)
        let task = Task { @MainActor in
            var out: [SearchHit] = []
            for await batch in stream {
                out.append(contentsOf: batch)
            }
            return out
        }
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            task.cancel()
        }
        let result = await task.value
        watchdog.cancel()
        return result
    }

    @Test func hiddenChannelFindsHiddenByName() async throws {
        let dir = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hits = await collect(SearchRequest(query: "nsneedle", scope: .directory(dir),
                                               searchNames: true, searchContents: false,
                                               includeHidden: true))
        let names = Set(hits.map(\.name))
        // Dot-hidden files, files in hidden directories, visible files and deep files all match by name
        #expect(names.contains(".hidden-nsneedle.txt"))
        #expect(names.contains("inside-nsneedle.txt"))
        #expect(names.contains("visible-nsneedle.txt"))
        #expect(names.contains("deep-nsneedle.txt"))
        #expect(!names.contains("unrelated.txt"))
    }

    @Test func skippedDirectoriesAreNotScanned() async throws {
        let dir = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hits = await collect(SearchRequest(query: "nsneedle", scope: .directory(dir),
                                               searchNames: true, searchContents: false,
                                               includeHidden: true))
        // The heavy directory node_modules is skipped
        #expect(!hits.contains { $0.name == "skip-nsneedle.txt" })
    }

    @Test func includeHiddenOffOmitsHiddenChannel() async throws {
        let dir = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Hidden channel off: Spotlight only, temp directories and hidden files are not indexed → hidden files must not appear
        let hits = await collect(SearchRequest(query: "nsneedle", scope: .directory(dir),
                                               searchNames: true, searchContents: false,
                                               includeHidden: false), timeout: 2)
        #expect(!hits.contains { $0.name == ".hidden-nsneedle.txt" })
        #expect(!hits.contains { $0.name == "inside-nsneedle.txt" })
    }

    @Test func resultsAreDeduplicatedByURL() async throws {
        let dir = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Both channels on: the same URL must never appear twice in the merged stream
        let hits = await collect(SearchRequest(query: "nsneedle", scope: .directory(dir),
                                               searchNames: true, searchContents: false,
                                               includeHidden: true))
        let paths = hits.map(\.url.path)
        #expect(Set(paths).count == paths.count)
    }

    @Test func emptyQueryFinishesImmediately() async throws {
        let dir = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hits = await collect(SearchRequest(query: "", scope: .directory(dir),
                                               searchNames: true, searchContents: false,
                                               includeHidden: true), timeout: 1)
        #expect(hits.isEmpty)
    }

    @Test func spotlightChannelStartsAndStopsWithoutCrash() async throws {
        let dir = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Loose channel A assertion: content search cancelled 0.5s after starting; the stream must end without crashing (index results are not required)
        let hits = await collect(SearchRequest(query: "nsneedle", scope: .directory(dir),
                                               searchNames: true, searchContents: true,
                                               includeHidden: false), timeout: 0.5)
        _ = hits  // result contents are not asserted (depends on Spotlight index state)
        #expect(Bool(true))
    }

    @Test func resultsAreCappedAtMaxResults() async throws {
        // Freeze root-cause regression: when hits exceed the cap the engine must cap and stop channels (otherwise main-thread full reads freeze and spike CPU).
        // Builds maxResults+200 matching files for channel B's recursive scan, asserting total stream output <= the cap.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nspace-search-cap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let n = SearchLimits.maxResults + 200
        for i in 0..<n {
            try Data("x".utf8).write(to: dir.appendingPathComponent("capneedle-\(i).txt"))
        }
        let hits = await collect(SearchRequest(query: "capneedle", scope: .directory(dir),
                                               searchNames: true, searchContents: false,
                                               includeHidden: true), timeout: 10)
        #expect(hits.count <= SearchLimits.maxResults)
        #expect(hits.count >= SearchLimits.maxResults - 50)   // really approaches the cap (proves many were scanned, and capped)
    }
    // MARK: v0.19.17: the four independent real causes of "visible but .claude unsearchable" (user report)

    /// Real cause (1) traversal order: `FileManager.enumerator` is a lazy pre-order DFS; after a depth-1 directory
    /// it walks the whole subtree before returning to the next depth-1 sibling. Measured on a real machine, `~/.claude` took DFS 15.5s
    /// to be **enumerated** (item 750k), BFS 0.006s (item 104).
    ///
    /// This assertion is **independent** of directory enumeration order (no luck involved): in the fixture root/{d1/leaf, d2/leaf},
    /// whichever of d1 or d2 DFS takes first, it must emit depth-2 before returning to the other depth-1
    /// → "monotonically non-decreasing depth" is necessarily broken. BFS always holds.
    @Test func levelOrderWalkEmitsNonDecreasingDepths() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("nspace-bfs-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        for d in ["d1", "d2"] {
            try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: root.appendingPathComponent("\(d)/leaf.txt"))
        }
        var depths: [Int] = []
        LevelOrderWalk.walk(root: root, skipDirectoryNames: [], shouldContinue: { true }) { _, depth, _ in
            depths.append(depth)
        }
        #expect(depths == depths.sorted(), "Depth must be monotonically non-decreasing, got \(depths)")
        #expect(depths.count == 4)                       // anti-empty assertion: the fixture really was walked
        #expect(depths.filter { $0 == 1 }.count == 2)    // both depth-1 directories come before depth-2
    }

    /// The **wiring** of real cause (1): the previous test only proves LevelOrderWalk itself is BFS; swap scan() back to DFS
    /// and it stays fully green (adversarial review measured 3/3). This test hits the actual hit sequence from scan().
    ///
    /// Fixture root/{m-dirA/m-inner, m-dirB/m-inner}, all four items match "nswire".
    /// Whichever directory DFS takes first it must go depth1→depth2→depth1→depth2; BFS is always 1,1,2,2.
    /// Independent of directory enumeration order.
    @Test func scanDeliversShallowHitsBeforeDeepOnes() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("nspace-wire-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        for d in ["nswire-dirA", "nswire-dirB"] {
            try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: root.appendingPathComponent("\(d)/nswire-inner.txt"))
        }
        var order: [SearchHit] = []
        SearchSession.scan(root: root,
                           request: SearchRequest(query: "nswire", scope: .directory(root),
                                                  includeHidden: true)) { order.append(contentsOf: $0) }
        let rootDepth = root.standardizedFileURL.pathComponents.count
        let depths = order.map { $0.url.standardizedFileURL.pathComponents.count - rootDepth }
        #expect(depths == depths.sorted(), "scan() depths must be monotonically non-decreasing, got \(depths)")
        #expect(depths.count == 4)                      // anti-empty assertion: all four items arrived
        #expect(depths.prefix(2).allSatisfy { $0 == 1 }) // both depth-1 directories come before any depth-2
    }

    /// Real cause (2) emit conditions: the old version emitted only at `batch.count >= 50` and at "whole tree scanned".
    /// Low-hit-rate queries (searching ".claude" under ~ has only 135 hits among 1.98M items) kept hits held on the stack,
    /// measured at 17.9s to the first batch (hit 50) and 45s to scan completion.
    ///
    /// The fixture's two hits sit at depth 1 and depth 3, separated by 5000 non-matching items.
    /// With timed emits the shallow hit goes out **in its own batch** first → at least 2 emits;
    /// with count-only emits 2 < 50 and only the final emit happens → the assertion must fail.
    @Test func sparseHitIsNotWithheldUntilScanEnds() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("nspace-flush-\(UUID().uuidString)")
        let deepDir = root.appendingPathComponent("bulk/deep")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: deepDir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("flushneedle-shallow.txt"))   // depth 1
        try Data("x".utf8).write(to: deepDir.appendingPathComponent("flushneedle-deep.txt"))   // depth 3
        for i in 0..<5000 {                                                                    // depth 2 padding
            try Data().write(to: root.appendingPathComponent("bulk/pad-\(i).bin"))
        }
        var emits: [[SearchHit]] = []
        SearchSession.scan(root: root,
                           request: SearchRequest(query: "flushneedle", scope: .directory(root),
                                                  includeHidden: true),
                           flushInterval: 1_000_000) { emits.append($0) }   // 1ms window, paired with a 5000-item (~12ms) fixture
        #expect(emits.count >= 2, "The shallow hit must go out alone first, got \(emits.count) emits")
        #expect(emits.first?.contains { $0.name == "flushneedle-shallow.txt" } == true,
                "The first batch must be the depth-1 hit, got\(emits.first?.map(\.name) ?? [])")
        #expect(emits.flatMap { $0 }.count == 2)         // anti-empty assertion: both hits arrived
    }

    /// Real cause (3): a directory in the skip list could **itself** never be a hit: the old skip branch did `continue`
    /// **before** the match test, so searching "node_modules" / "Library" / ".git" could not find that directory itself.
    @Test func skippedDirectoryItselfCanStillBeAHit() async throws {
        // Dedicated fixture: the file name inside the heavy directory **also** contains the query. With the shared fixture's skip-nsneedle.txt,
        // the "still not descended into" check would be trivially true (the query node_modules cannot match it), asserting nothing.
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("nspace-skip-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir.appendingPathComponent("node_modules"),
                               withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("node_modules/node_modules-inside.txt"))
        let hits = await collect(SearchRequest(query: "node_modules", scope: .directory(dir),
                                               searchNames: true, searchContents: false,
                                               includeHidden: true))
        #expect(hits.contains { $0.name == "node_modules" && $0.isDirectory },
                "The heavy directory itself must be matchable, got\(hits.map(\.name))")
        // Still not descended into: the file inside that **also matches** must not appear (skip semantics not changed along the way)
        #expect(!hits.contains { $0.name == "node_modules-inside.txt" },
                "Skip semantics must be preserved, got\(hits.map(\.name))")
    }

    /// Real cause (4) the result cap starves channel B: channel A can read a full 2000 in the first gathering notification,
    /// `append()` then hits `keptCount >= maxResults` → `teardown()` → `scanTask.cancel()`,
    /// and the batch held on channel B's stack is discarded. So for any word with ≥2000 Spotlight hits,
    /// "Include hidden files" is a silent no-op switch. With the reserve channel A cannot take all slots.
    @Test func spotlightBudgetReservesRoomForTheScanChannel() {
        // Channel B running: channel A reads at most maxResults - scanReserve at once (the old formula gave all of maxResults)
        #expect(SearchLimits.spotlightReadBudget(kept: 0, scanAlive: true)
                == SearchLimits.maxResults - SearchLimits.scanReserve)
        #expect(SearchLimits.scanReserve > 0)                       // anti-hardcoding: the reserve must really have a size
        // Channel B done: no more reserve, channel A may use the full quota (otherwise results are wasted)
        #expect(SearchLimits.spotlightReadBudget(kept: 0, scanAlive: false) == SearchLimits.maxResults)
        // Budget reaches zero near the cap, never negative
        #expect(SearchLimits.spotlightReadBudget(kept: SearchLimits.maxResults, scanAlive: true) == 0)
        #expect(SearchLimits.spotlightReadBudget(kept: SearchLimits.maxResults + 99, scanAlive: false) == 0)
    }
    /// The cap must be guarded **per item**, not by the coincidence "batches are always 50 so it lands on 2000":
    /// with timed emits batch sizes vary, and detecting overshoot afterwards would keep up to 49 extra.
    /// Feeds batches of 7 directly (7 does not divide 2000); end-to-end fixtures cannot produce this condition (hits all in one directory,
    /// batches always 50, keptCount lands exactly on the cap; the first assertion written that way was a false green).
    @Test func hardCapLandsExactlyOnLimitWithIrregularBatches() async throws {
        let (stream, cont) = AsyncStream<[SearchHit]>.makeStream()
        let session = SearchSession(request: SearchRequest(query: "capx", scope: .global),
                                    continuation: cont)
        let collector = Task { @MainActor in
            var out: [SearchHit] = []
            for await b in stream { out.append(contentsOf: b) }
            return out
        }
        var i = 0
        while i < SearchLimits.maxResults + 100 {
            let batch = (0..<7).map { k -> SearchHit in
                SearchHit(url: URL(fileURLWithPath: "/tmp/nspace-capx-\(i + k)"),
                          name: "capx-\(i + k)", isDirectory: false,
                          size: nil, modified: nil, contentTypeID: nil)
            }
            session.append(batch)
            i += 7
        }
        session.stop()
        let got = await collector.value
        #expect(got.count == SearchLimits.maxResults, "got \(got.count), must equal the cap exactly")
        #expect(Set(got.map(\.url.path)).count == got.count)   // anti-empty assertion: still this count after dedup
    }
    /// First batch throttle exemption: after the scan side's 150ms emit window, append() adds a 300ms throttle,
    /// so a sparse query's first result takes ~450ms to appear. The first batch goes out directly; only later ones are throttled.
    ///
    /// This is **not** a timing assertion: `hasYielded` is final the moment append returns,
    /// so it is deterministic. Testing the same thing end to end would be a flaky timing assertion, which we do not write.
    @Test func firstBatchBypassesThrottleButLaterSmallBatchesDoNot() async throws {
        let (stream, cont) = AsyncStream<[SearchHit]>.makeStream()
        let session = SearchSession(request: SearchRequest(query: "thr", scope: .global),
                                    continuation: cont)
        func hit(_ i: Int) -> SearchHit {
            SearchHit(url: URL(fileURLWithPath: "/tmp/nspace-thr-\(i)"), name: "thr-\(i)",
                      isDirectory: false, size: nil, modified: nil, contentTypeID: nil)
        }
        // First batch: must be pushed **immediately** (not put on the 300ms schedule)
        session.append([hit(1)])
        #expect(session.hasYielded, "The first batch must be pushed immediately, not held by the 300ms throttle")
        #expect(session.bufferedCount == 0, "The first batch should have emptied the buffer, got\(session.bufferedCount)")
        // Second small batch: the throttle must still apply (otherwise every hit crosses threads, wasting CPU)
        session.append([hit(2)])
        #expect(session.bufferedCount == 1, "The second small batch must stay buffered under the throttle, got\(session.bufferedCount)")
        session.stop()
        _ = stream
    }

    // MARK: Multi-term queries (user report: searching "override md" in ~/.claude reported not found, though OVERRIDE.md was right there)

    /// Fixture: dot-separated names in a different case from the query: the minimal reproduction of the user's bug.
    ///
    /// Note that basenames must all differ: APFS is case-insensitive by default, so `NSOVERRIDE.md` and `nsoverride.md`
    /// in one directory are the **same file**, and writing twice leaves one (the first fixture did exactly that, giving two false reds).
    /// "Case-matching first" is a ranking concern, covered by SearchRanking's pure function tests, not verified on the file system.
    func makeCaseFixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nspace-case-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in ["NSOVERRIDE.md", "nsoverridetwo.md", "unrelated.txt"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(f))
        }
        return dir
    }

    /// This is the very bug the user reported: a query with spaces must hit dot-separated names.
    /// Case was never the cause ("nsoverride" alone always hit); the space was.
    @Test func spaceSeparatedTermsMatchAcrossPunctuation() async throws {
        let dir = try makeCaseFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hits = await collect(SearchRequest(query: "nsoverride md", scope: .directory(dir),
                                               searchNames: true, searchContents: false,
                                               includeHidden: true))
        let names = Set(hits.map(\.name))
        // The all-caps one must hit too: case-insensitive (this always held); the space is what this fix addressed
        #expect(names.contains("NSOVERRIDE.md"), "A query with spaces must hit NSOVERRIDE.md, got\(names)")
        #expect(names.contains("nsoverridetwo.md"))
        #expect(!names.contains("unrelated.txt"))
    }

    /// Term order does not matter: AND matching is not sequence matching
    @Test func termOrderDoesNotMatter() async throws {
        let dir = try makeCaseFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hits = await collect(SearchRequest(query: "md nsoverride", scope: .directory(dir),
                                               searchNames: true, searchContents: false,
                                               includeHidden: true))
        #expect(Set(hits.map(\.name)).contains("NSOVERRIDE.md"))
    }

    /// Every term must hit (AND, not OR): one unmatched term voids the entry
    @Test func allTermsMustMatchNotAny() async throws {
        let dir = try makeCaseFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hits = await collect(SearchRequest(query: "nsoverride zzz", scope: .directory(dir),
                                               searchNames: true, searchContents: false,
                                               includeHidden: true))
        #expect(hits.isEmpty, "The second term matches nothing, so the query should have no hits, got\(hits.map(\.name))")
    }

    /// A whitespace-only query must finish immediately: it splits into an empty array, and feeding that to andPredicate yields an **always-true** predicate
    /// (which would push the whole disk to the main thread). The old guard checked only query.isEmpty and could not stop a single space.
    @Test func whitespaceOnlyQueryFinishesImmediately() async throws {
        let dir = try makeCaseFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hits = await collect(SearchRequest(query: "   ", scope: .directory(dir),
                                               searchNames: true, searchContents: false,
                                               includeHidden: true), timeout: 2)
        #expect(hits.isEmpty)
    }

    @Test func queryTermsSplitsAndMatches() {
        #expect(QueryTerms.split("override md") == ["override", "md"])
        #expect(QueryTerms.split("  a   b  ") == ["a", "b"])
        #expect(QueryTerms.split("   ").isEmpty)
        #expect(QueryTerms.matches("OVERRIDE.md", terms: ["override", "md"]))
        #expect(QueryTerms.matches("OVERRIDE.md", terms: ["MD", "OverRide"]))
        #expect(!QueryTerms.matches("OVERRIDE.md", terms: ["override", "zzz"]))
        // An empty term list never matches: otherwise an empty query would return the whole disk
        #expect(!QueryTerms.matches("anything", terms: []))
    }
}
