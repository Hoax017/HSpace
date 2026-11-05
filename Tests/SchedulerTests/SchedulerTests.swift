import Foundation
import HSpaceContracts
import HSpaceTestSupport
import Scheduler
import Testing

private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

private func job(_ priority: SchedulerPriority = .normal, reads: [String] = [], writes: [String] = [],
                 pausable: Bool = true) -> SchedulerRequest {
    SchedulerRequest(id: UUID(), priority: priority, claims: PathClaims(reads: reads.map(url), writes: writes.map(url)),
                     pausableWhileRunning: pausable)
}

@Suite struct QueueOrderTests {
    @Test func theSlotLimitHolds() {
        let scheduler = Scheduler(maxConcurrent: 2)
        let jobs = (0..<3).map { job(writes: ["/q/\($0)"]) }
        jobs.forEach(scheduler.enqueue)
        #expect(scheduler.takeRunnable() == [jobs[0].id, jobs[1].id])
        #expect(scheduler.takeRunnable().isEmpty)
        scheduler.finished(jobs[0].id)
        #expect(scheduler.takeRunnable() == [jobs[2].id])
    }

    @Test func aLimitBelowOneStillRunsOne() {
        let scheduler = Scheduler(maxConcurrent: 0)
        let only = job()
        scheduler.enqueue(only)
        #expect(scheduler.takeRunnable() == [only.id])
    }

    @Test func higherPriorityStartsFirstAndEqualsKeepTheirOrder() {
        let scheduler = Scheduler(maxConcurrent: 1)
        let low = job(.low), first = job(), second = job(), high = job(.high)
        [low, first, second, high].forEach(scheduler.enqueue)
        var order: [UUID] = []
        for _ in 0..<4 {
            let next = scheduler.takeRunnable()
            order += next
            next.forEach(scheduler.finished)
        }
        #expect(order == [high.id, first.id, second.id, low.id])
    }

    @Test func changingPriorityReordersTheQueue() {
        let scheduler = Scheduler(maxConcurrent: 1)
        let first = job(), second = job()
        [first, second].forEach(scheduler.enqueue)
        scheduler.setPriority(.high, for: second.id)
        #expect(scheduler.takeRunnable() == [second.id])
    }

    @Test func aHigherLimitStartsMoreAtOnce() {
        let scheduler = Scheduler(maxConcurrent: 1)
        let jobs = [job(), job()]
        jobs.forEach(scheduler.enqueue)
        #expect(scheduler.takeRunnable().count == 1)
        scheduler.setMaxConcurrent(2)
        #expect(scheduler.takeRunnable().count == 1)
    }

    @Test func quickEditsDefaultToHighPriority() {
        #expect(SchedulerPriority.default(for: .rename) == .high)
        #expect(SchedulerPriority.default(for: .newFolder) == .high)
        #expect(SchedulerPriority.default(for: .copy) == .normal)
    }
}

@Suite struct PathLockTests {
    private func conflict(_ a: PathClaims, _ b: PathClaims) -> Bool { a.conflicts(with: b) && b.conflicts(with: a) }

    @Test func readsShareAndWritesExclude() {
        let read = PathClaims(reads: [url("/a/x")]), write = PathClaims(writes: [url("/a/x")])
        #expect(!conflict(read, read))
        #expect(conflict(read, write))
        #expect(conflict(write, write))
    }

    @Test func aLockCoversTheSubtreeInBothDirections() {
        #expect(conflict(PathClaims(writes: [url("/a")]), PathClaims(reads: [url("/a/b/c")])))
        #expect(conflict(PathClaims(reads: [url("/a")]), PathClaims(writes: [url("/a/b/c")])))
    }

    @Test func siblingsAndSharedPrefixesDoNotConflict() {
        #expect(!conflict(PathClaims(writes: [url("/a/b")]), PathClaims(writes: [url("/a/c")])))
        #expect(!conflict(PathClaims(writes: [url("/a/b")]), PathClaims(writes: [url("/a/bc")])))
    }

    @Test func caseDoesNotHideAConflict() {
        #expect(conflict(PathClaims(writes: [url("/a/Report")]), PathClaims(writes: [url("/A/report")])))
    }

    @Test func aLinkDoesNotHideAConflict() throws {
        let dir = try FaultFixture.tempDir("hspace-scheduler")
        defer { FaultFixture.remove(dir) }
        let real = dir.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(conflict(PathClaims(writes: [real.appendingPathComponent("new")]),
                         PathClaims(writes: [link.appendingPathComponent("new")])))
    }

    @Test func claimsFollowTheKindOfOperation() {
        let source = url("/s/file"), destination = url("/d")
        let copy = PathClaims(spec: OperationSpec(kind: .copy, sources: [source], destination: destination))
        #expect(copy.reads.count == 1 && copy.writes.count == 1)
        let move = PathClaims(spec: OperationSpec(kind: .move, sources: [source], destination: destination))
        #expect(move.reads.isEmpty && move.writes.count == 2)
        let rename = PathClaims(spec: OperationSpec(kind: .rename, sources: [source], newName: "other"))
        #expect(rename.writes.count == 2)
        #expect(!rename.conflicts(with: PathClaims(reads: [url("/s/third")])))
        let extract = PathClaims(spec: OperationSpec(kind: .extract, sources: [source],
                                                     archiveOptions: ArchiveOptions(extractInto: destination)))
        #expect(extract.conflicts(with: PathClaims(reads: [destination])))
        #expect(!extract.conflicts(with: PathClaims(reads: [source])))
    }

    @Test func aJobWaitsForAPathAndStartsWhenItIsFree() {
        let scheduler = Scheduler(maxConcurrent: 4)
        let first = job(writes: ["/a"]), second = job(reads: ["/a/b"]), other = job(writes: ["/z"])
        [first, second, other].forEach(scheduler.enqueue)
        #expect(scheduler.takeRunnable() == [first.id, other.id])
        #expect(scheduler.snapshot().status(of: second.id)?.phase == .waitingForPath)
        scheduler.finished(first.id)
        #expect(scheduler.takeRunnable() == [second.id])
    }

    @Test func aJobCannotOvertakeAnEarlierJobItConflictsWith() {
        let scheduler = Scheduler(maxConcurrent: 4)
        let running = job(writes: ["/a"]), queued = job(writes: ["/a", "/b"]), later = job(writes: ["/b"])
        [running, queued, later].forEach(scheduler.enqueue)
        #expect(scheduler.takeRunnable() == [running.id])
        #expect(scheduler.snapshot().status(of: later.id)?.phase == .waitingForPath)
    }

    @Test func readersShareWhileAWriterWaits() {
        let scheduler = Scheduler(maxConcurrent: 4)
        let one = job(reads: ["/a"]), two = job(reads: ["/a"]), writer = job(writes: ["/a"])
        [one, two, writer].forEach(scheduler.enqueue)
        #expect(scheduler.takeRunnable() == [one.id, two.id])
        scheduler.finished(one.id)
        #expect(scheduler.takeRunnable().isEmpty)
        scheduler.finished(two.id)
        #expect(scheduler.takeRunnable() == [writer.id])
    }

    @Test func aHugeSelectionStillConflicts() {
        let scheduler = Scheduler(maxConcurrent: 2)
        let paths = (0..<5_000).map { "/big/folder/\($0)" }
        let holder = job(writes: paths), waiter = job(reads: ["/big/folder/4999"])
        [holder, waiter].forEach(scheduler.enqueue)
        #expect(scheduler.takeRunnable() == [holder.id])
    }
}

@Suite struct PauseTests {
    @Test func pausingAQueuedJobLetsOthersPass() {
        let scheduler = Scheduler(maxConcurrent: 1)
        let first = job(writes: ["/a"]), second = job(writes: ["/a/b"])
        [first, second].forEach(scheduler.enqueue)
        #expect(scheduler.pause(first.id))
        #expect(scheduler.takeRunnable() == [second.id])
        #expect(scheduler.snapshot().status(of: first.id)?.phase == .paused)
        scheduler.finished(second.id)
        scheduler.resume(first.id)
        #expect(scheduler.takeRunnable() == [first.id])
    }

    @Test func aPausedQueueStartsNothingUntilResumed() {
        let scheduler = Scheduler(maxConcurrent: 2)
        let only = job()
        scheduler.pauseAll()
        scheduler.enqueue(only)
        #expect(scheduler.takeRunnable().isEmpty)
        #expect(scheduler.snapshot().isPaused)
        scheduler.resumeAll()
        #expect(scheduler.takeRunnable() == [only.id])
    }

    @Test func aRunningJobThatCannotStopRefusesPause() {
        let scheduler = Scheduler()
        let only = job(pausable: false)
        scheduler.enqueue(only)
        #expect(scheduler.snapshot().status(of: only.id)?.canPause == true)
        _ = scheduler.takeRunnable()
        #expect(scheduler.snapshot().status(of: only.id)?.canPause == false)
        #expect(!scheduler.pause(only.id))
        #expect(scheduler.snapshot().status(of: only.id)?.phase == .running)
    }

    @Test func aPausedRunningJobKeepsItsLocksButFreesItsSlot() {
        let scheduler = Scheduler(maxConcurrent: 1)
        let holder = job(writes: ["/a"]), blocked = job(writes: ["/a/b"]), free = job(writes: ["/z"])
        [holder, blocked, free].forEach(scheduler.enqueue)
        _ = scheduler.takeRunnable()
        scheduler.pause(holder.id)
        #expect(scheduler.takeRunnable() == [free.id])
        #expect(scheduler.snapshot().status(of: blocked.id)?.phase == .waitingForPath)
    }

    private func stopped(_ scheduler: Scheduler, _ id: UUID) -> DispatchSemaphore {
        let released = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            scheduler.waitWhilePaused(id)
            released.signal()
        }
        return released
    }

    @Test func theGateStopsAPausedJobUntilResume() {
        let scheduler = Scheduler()
        let only = job()
        scheduler.enqueue(only)
        _ = scheduler.takeRunnable()
        scheduler.pause(only.id)
        let released = stopped(scheduler, only.id)
        #expect(released.wait(timeout: .now() + 0.1) == .timedOut)
        scheduler.resume(only.id)
        #expect(released.wait(timeout: .now() + 5) == .success)
    }

    @Test func thePausedQueueStopsRunningJobsToo() {
        let scheduler = Scheduler()
        let only = job()
        scheduler.enqueue(only)
        _ = scheduler.takeRunnable()
        scheduler.pauseAll()
        #expect(scheduler.snapshot().status(of: only.id)?.phase == .paused)
        let released = stopped(scheduler, only.id)
        #expect(released.wait(timeout: .now() + 0.1) == .timedOut)
        scheduler.resumeAll()
        #expect(released.wait(timeout: .now() + 5) == .success)
    }

    @Test func cancellingAPausedJobReleasesTheGate() {
        let scheduler = Scheduler()
        let only = job()
        scheduler.enqueue(only)
        _ = scheduler.takeRunnable()
        scheduler.pause(only.id)
        let released = stopped(scheduler, only.id)
        scheduler.withdraw(only.id)
        #expect(released.wait(timeout: .now() + 5) == .success)
        #expect(scheduler.snapshot().status(of: only.id) != nil)
        scheduler.finished(only.id)
        #expect(scheduler.snapshot().jobs.isEmpty)
    }

    @Test func theGateIsOpenForUnknownJobs() {
        Scheduler().waitWhilePaused(UUID())
    }

    @Test func resumeWakesTheOwner() {
        let scheduler = Scheduler()
        let woken = DispatchSemaphore(value: 0)
        scheduler.setWakeHandler { woken.signal() }
        scheduler.resumeAll()
        #expect(woken.wait(timeout: .now() + 5) == .success)
    }

    @Test func changesAreReported() async {
        let scheduler = Scheduler()
        var iterator = scheduler.changes().makeAsyncIterator()
        #expect(await iterator.next()?.jobs.isEmpty == true)
        let only = job()
        scheduler.enqueue(only)
        #expect(await iterator.next()?.status(of: only.id)?.phase == .queued)
    }
}
