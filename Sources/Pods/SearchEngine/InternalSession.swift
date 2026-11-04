import Foundation
import UniformTypeIdentifiers
import NSpaceContracts

/// One search session: channel A (Spotlight/NSMetadataQuery) + channel B (recursive hidden file scan) → merged and deduped by url, pushed in batches.
///
/// Threading invariant (the basis for @unchecked Sendable): all mutable state is touched only on the main thread:
/// channel A notifications are delivered via query.operationQueue = .main; channel B's background scan feeds back via DispatchQueue.main;
/// start() is called on the main thread (engine API is @MainActor); stop() hops to the main thread itself.
final class SearchSession: NSObject, @unchecked Sendable {
    private let request: SearchRequest
    private let continuation: AsyncStream<[SearchHit]>.Continuation

    // ---- Everything below is main-thread state ----
    private var query: NSMetadataQuery?
    private var scanTask: Task<Void, Never>?
    private var buffer: [SearchHit] = []
    private var seenPaths: Set<String> = []
    /// Number of unfinished channels; zero = the session wraps up naturally
    private var pendingChannels = 0
    private var flushScheduled = false
    private var finished = false
    /// Kept (deduped) hit count: both channels stop at SearchLimits.maxResults, ruling out main-thread full reads freezing the app
    private var keptCount = 0
    /// Spotlight incremental read cursor (gathering progress reads only the newly arrived segment)
    private var spotlightReadIndex = 0
    /// Whether channel B is still running: channel A reserves slots for it accordingly (see SearchLimits.scanReserve)
    private var scanRunning = false

    init(request: SearchRequest, continuation: AsyncStream<[SearchHit]>.Continuation) {
        self.request = request
        self.continuation = continuation
    }

    // MARK: Lifecycle

    /// Called on the main thread
    func start() {
        let wantsSpotlight = request.searchNames || request.searchContents
        // Content search uses channel A only; channel B handles only name search (honest: no self-built full-text index)
        let wantsScan = request.includeHidden && request.searchNames
        // The criterion is **non-empty after splitting**, not a non-empty raw string: an all-whitespace query (a stray space) splits into zero terms,
        // and `andPredicateWithSubpredicates([])` is an **always-true** predicate, which would push the whole disk to the main thread as hits.
        guard !QueryTerms.split(request.query).isEmpty, wantsSpotlight || wantsScan else {
            finished = true
            continuation.finish()
            return
        }
        if wantsSpotlight { startSpotlight() }
        if wantsScan { startScan() }
    }

    /// Callable from any thread (onTermination callback); the actual teardown happens on the main thread
    func stop() {
        if Thread.isMainThread {
            teardown()
        } else {
            DispatchQueue.main.async { self.teardown() }
        }
    }

    private func teardown() {
        guard !finished else { return }
        finished = true
        scanRunning = false
        scanTask?.cancel()
        scanTask = nil
        if let query {
            NotificationCenter.default.removeObserver(self, name: nil, object: query)
            query.stop()
            self.query = nil
        }
        continuation.finish()
    }

    // MARK: Channel A: Spotlight (NSMetadataQuery, ObjC legacy wrapped as notification → batch)

    private func startSpotlight() {
        pendingChannels += 1
        let q = NSMetadataQuery()
        // Within each dimension terms are ANDed ("override md" → name has both override and md); dimensions are ORed.
        // In the whole-string CONTAINS era, queries with spaces could never match dot-separated names like `OVERRIDE.md` (user report).
        let terms = QueryTerms.split(request.query)
        func allTerms(of key: String) -> NSPredicate {
            let subs = terms.map { NSPredicate(format: "%K CONTAINS[cd] %@", key, $0) }
            // NSMetadataQuery rejects **single-child** compound predicates (an existing comment noted the same limit for OR; AND is the same):
            // wrapping one subpredicate in AND throws NSInvalidArgumentException and crashes the process on the spot.
            // Single-word queries are the most common use, so this is no edge case. Use a single one directly, compound only for several.
            return subs.count == 1 ? subs[0]
                : NSCompoundPredicate(andPredicateWithSubpredicates: subs)
        }
        var predicates: [NSPredicate] = []
        if request.searchNames {
            predicates.append(allTerms(of: NSMetadataItemFSNameKey))
        }
        if request.searchContents {
            predicates.append(allTerms(of: NSMetadataItemTextContentKey))
        }
        // NSMetadataQuery rejects a single-child OR compound predicate: use one condition directly, OR only for several
        q.predicate = predicates.count == 1
            ? predicates[0]
            : NSCompoundPredicate(orPredicateWithSubpredicates: predicates)
        switch request.scope {
        case .global:
            q.searchScopes = [NSMetadataQueryLocalComputerScope]
        case .directory(let url):
            q.searchScopes = [url]
        }
        q.operationQueue = .main  // notification delivery and result access are all on the main thread (threading invariant)
        q.notificationBatchingInterval = 0.3
        NotificationCenter.default.addObserver(self, selector: #selector(spotlightProgressed(_:)),
                                               name: .NSMetadataQueryGatheringProgress, object: q)
        NotificationCenter.default.addObserver(self, selector: #selector(spotlightFinished(_:)),
                                               name: .NSMetadataQueryDidFinishGathering, object: q)
        query = q
        q.start()
    }

    @objc private func spotlightProgressed(_ note: Notification) {
        drainSpotlight(final: false)
    }

    @objc private func spotlightFinished(_ note: Notification) {
        drainSpotlight(final: true)
    }

    /// Main thread (guaranteed by operationQueue = .main)
    private func drainSpotlight(final: Bool) {
        guard let query, !finished else { return }
        query.disableUpdates()
        let count = query.resultCount
        var hits: [SearchHit] = []
        // Hard cap + channel B reserve: never read hundreds of thousands of results on the main thread, and never eat all slots at once and starve channel B
        // `!final` is required: after the wrap-up drain the query is stopped and released, there is no next chance.
        // Still reserving for channel B then would **permanently lose** those 500 slots' worth of Spotlight results, with the user never seeing
        // the "Showing the first N results" notice. A real bug caught in review, not an imagined one.
        let readBudget = SearchLimits.spotlightReadBudget(kept: keptCount,
                                                          scanAlive: scanRunning && !final)
        while spotlightReadIndex < count, hits.count < readBudget {
            if let item = query.result(at: spotlightReadIndex) as? NSMetadataItem,
               let hit = Self.hit(from: item) {
                hits.append(hit)
            }
            spotlightReadIndex += 1
        }
        query.enableUpdates()
        append(hits)
        if final {
            NotificationCenter.default.removeObserver(self, name: nil, object: query)
            query.stop()
            self.query = nil
            channelDone()
        }
    }

    /// Display attributes come straight from metadata (no extra stat)
    private static func hit(from item: NSMetadataItem) -> SearchHit? {
        guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
        let url = URL(fileURLWithPath: path)
        let typeID = item.value(forAttribute: NSMetadataItemContentTypeKey) as? String
        let isDirectory = typeID.flatMap { UTType($0)?.conforms(to: .directory) } ?? false
        return SearchHit(
            url: url,
            name: (item.value(forAttribute: NSMetadataItemFSNameKey) as? String) ?? url.lastPathComponent,
            isDirectory: isDirectory,
            size: (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value,
            modified: item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date,
            contentTypeID: typeID)
    }

    // MARK: Channel B: recursive hidden file scan (goes beyond Spotlight: index-independent, does not skip hidden items)

    private func startScan() {
        pendingChannels += 1
        scanRunning = true
        let request = self.request
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            for root in Self.scanRoots(for: request.scope) {
                guard !Task.isCancelled else { break }
                Self.scan(root: root, request: request) { batch in
                    DispatchQueue.main.async { self?.append(batch) }
                }
            }
            DispatchQueue.main.async {
                self?.scanRunning = false     // channel B is done, channel A no longer needs a reserve
                self?.channelDone()
            }
        }
    }

    /// Global scope = home directory + external volume roots (never scan "/": it would drag in the mass of read-only /System content)
    private static func scanRoots(for scope: SearchRequest.Scope) -> [URL] {
        switch scope {
        case .directory(let url):
            return [url]
        case .global:
            var roots = [FileManager.default.homeDirectoryForCurrentUser]
            let volumes = FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
            roots += volumes.filter { $0.path != "/" }
            return roots
        }
    }

    /// Background thread: level-order (BFS) walk + case-insensitive file name contains match.
    /// Both emit conditions are required (each came from a real failing case, see CHANGELOG v0.19.17):
    ///   (1) `batch.count >= 50`: the original one, only adequate for high-hit-rate queries;
    ///   (2) **at least flushInterval since the last emit**: for low-hit-rate queries (such as ".claude", 135 hits among 1.98M items under ~)
    ///      relying on (1) means waiting for hit 50, measured at 17.9s; relying on "scan finished" takes 45s.
    /// The clock is read only when batch is non-empty (short-circuit), so 2M iterations barely pay for it
    /// (`DispatchTime.now().uptimeNanoseconds` measured at 10ns per call).
    static let flushInterval: UInt64 = 150_000_000   // 150ms

    /// internal rather than private: pod self-tests drive it directly to test emit timing precisely,
    /// without being blurred by append()'s 300ms throttle (@testable import exposes only internal).
    /// `flushInterval` is a parameter with a default rather than a mutable static: production call sites are unchanged, tests can pass 1ms
    /// for deterministic assertions on small fixtures, and no mutable state is shared across tests.
    static func scan(root: URL, request: SearchRequest,
                     flushInterval: UInt64 = SearchSession.flushInterval,
                     emit: ([SearchHit]) -> Void) {
        // Display attributes fetched only on a hit (a miss does not spend a single extra stat)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey,
                                         .contentModificationDateKey, .contentTypeKey]
        var batch: [SearchHit] = []
        var lastEmit = DispatchTime.now().uptimeNanoseconds

        func flush() {
            guard !batch.isEmpty else { return }
            emit(batch)
            batch = []
            lastEmit = DispatchTime.now().uptimeNanoseconds
        }
        /// Emit if batch is non-empty and the throttle window has passed (the !isEmpty short-circuit keeps the clock read out of the vast majority of iterations)
        func flushIfDue() {
            guard !batch.isEmpty,
                  DispatchTime.now().uptimeNanoseconds - lastEmit >= flushInterval else { return }
            flush()
        }

        // Split once and only compare in the loop: two million iterations do not repeat the splitting cost
        let terms = QueryTerms.split(request.query)
        LevelOrderWalk.walk(root: root,
                            skipDirectoryNames: request.skippedDirectoryNames,
                            shouldContinue: { !Task.isCancelled }) { url, _, isDir in
            let name = url.lastPathComponent
            guard QueryTerms.matches(name, terms: terms) else {
                flushIfDue()          // misses must advance timed emits too, or a lone hit would be held until the scan ends
                return
            }
            let rv = try? url.resourceValues(forKeys: keys)
            batch.append(SearchHit(
                url: url, name: name,
                isDirectory: rv?.isDirectory ?? isDir,
                size: (rv?.fileSize).map(Int64.init),
                modified: rv?.contentModificationDate,
                contentTypeID: rv?.contentType?.identifier))
            if batch.count >= 50 { flush() } else { flushIfDue() }
        }
        flush()
    }

    // MARK: Dedup merge + throttled batch push (main thread)

    /// internal rather than private: the cap logic lives here, and self-tests must feed **misaligned** batches directly
    /// (end-to-end fixture hits all sit in one directory, batches are always 50, and keptCount lands exactly on the cap,
    ///  which cannot reveal overshoot: the first version passed falsely this way)
    func append(_ hits: [SearchHit]) {
        guard !finished, !hits.isEmpty else { return }
        for hit in hits {
            // The hard cap is guarded per item: before this change batches were always 50 and keptCount landed exactly on 2000;
            // with timed emits batch sizes vary, and detecting overshoot afterwards would keep up to 49 extra.
            // Note: check the cap before insert; the reverse marks paths that were not kept as "seen".
            guard keptCount < SearchLimits.maxResults else { break }
            guard seenPaths.insert(hit.url.path).inserted else { continue }
            buffer.append(hit)
            keptCount += 1
        }
        // Hit the hard cap: flush now and stop both channels (NSMetadataQuery.stop + scan Task cancel), CPU drops immediately
        if keptCount >= SearchLimits.maxResults {
            flushNow()
            teardown()
            return
        }
        // The first batch skips the throttle: for sparse queries the 300ms throttle on top of the 150ms scan emit window
        // puts the first result on screen after 450ms. Push the first batch directly; only later ones are throttled.
        if !hasYielded {
            flushNow()
        } else if buffer.count >= 50 {
            flushNow()
        } else if !flushScheduled, !buffer.isEmpty {
            // Timed via dispatch rather than a RunLoop Timer: no RunLoop mode dependency (equally reliable in test environments)
            flushScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                self.flushScheduled = false
                self.flushNow()
            }
        }
    }

    /// Whether at least one batch has been pushed (lets the first batch skip the 300ms throttle).
    /// internal rather than private: first-batch throttle exemption must be asserted **deterministically**;
    /// testing it end to end would be a timing assertion (flaky), while this flag is final the moment append returns.
    var hasYielded = false
    /// Count currently held in the buffer and not yet pushed (verifies "second small batch is still throttled")
    var bufferedCount: Int { buffer.count }

    private func flushNow() {
        guard !finished, !buffer.isEmpty else { return }
        continuation.yield(buffer)
        hasYielded = true
        buffer = []
    }

    private func channelDone() {
        guard !finished else { return }
        pendingChannels -= 1
        flushNow()
        if pendingChannels <= 0 {
            teardown()
        }
    }
}
