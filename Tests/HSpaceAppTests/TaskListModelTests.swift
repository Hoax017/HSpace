import Foundation
import HSpaceContracts
import Scheduler
import Testing
@testable import HSpaceApp

private func projection(_ id: UUID, _ state: RunState, done: Int64 = 0, total: Int64 = 0) -> OperationProjection {
    OperationProjection(id: id, kind: .copy, state: state, filesDone: 0, filesTotal: 0,
                        bytesDone: done, bytesTotal: total, currentPath: nil)
}

/// Real snapshots from the real scheduler, driven into the wanted phases.
private func snapshot(queued: [UUID] = [], paused: [UUID] = [], running: [UUID] = []) -> SchedulerSnapshot {
    let scheduler = Scheduler(maxConcurrent: 4)
    for id in running { scheduler.enqueue(SchedulerRequest(id: id, pausableWhileRunning: true)) }
    _ = scheduler.takeRunnable()
    for id in queued + paused { scheduler.enqueue(SchedulerRequest(id: id)) }
    paused.forEach { scheduler.pause($0) }
    return scheduler.snapshot()
}

@Suite struct TaskListModelTests {
    @Test func phasesComeFromTheScheduler() {
        let running = UUID(), paused = UUID(), queued = UUID()
        var model = TaskListModel()
        for id in [running, paused, queued] { model.apply(projection(id, .pending)) }
        model.apply(snapshot(queued: [queued], paused: [paused], running: [running]))
        let phases = Dictionary(uniqueKeysWithValues: model.entries.map { ($0.id, $0.phase) })
        #expect(phases == [running: .active, paused: .paused, queued: .queued])
    }

    @Test func aProjectionWithoutAJobStillShows() {
        let pending = UUID(), scanning = UUID()
        var model = TaskListModel()
        model.apply(projection(pending, .pending))
        model.apply(projection(scanning, .scanning))
        #expect(model.entries.map(\.phase) == [.queued, .active])
    }

    @Test func aFinishedRunWinsOverALaggingSnapshot() {
        let id = UUID()
        var model = TaskListModel()
        model.apply(snapshot(running: [id]))
        model.apply(projection(id, .completed))
        #expect(model.entries.map(\.phase) == [.finished])
        #expect(!model.hasUnfinished)
    }

    @Test func aJobNotYetProjectedIsIgnored() {
        var model = TaskListModel()
        model.apply(snapshot(queued: [UUID()]))
        #expect(model.entries.isEmpty)
    }

    @Test func theSummaryCountsAndAddsBytes() {
        let first = UUID(), second = UUID(), third = UUID()
        var model = TaskListModel()
        model.apply(projection(first, .running, done: 25, total: 100))
        model.apply(projection(second, .running, done: 25, total: 100))
        model.apply(projection(third, .pending))
        model.apply(snapshot(queued: [third], running: [first, second]))
        let summary = model.summary
        #expect(summary.running == 2 && summary.waiting == 1 && summary.paused == 0)
        #expect(summary.unfinished == 3)
        #expect(summary.fraction == 0.25)
    }

    @Test func idleSummaryIsEmpty() {
        var model = TaskListModel()
        let id = UUID()
        model.apply(projection(id, .completed))
        #expect(model.summary == TaskStatusSummary())
    }

    @Test func automaticClearingKeepsFailures() {
        let good = UUID(), bad = UUID(), running = UUID()
        var model = TaskListModel()
        model.apply(projection(good, .completed))
        model.apply(projection(bad, .failed(message: "no", errorClass: .external)))
        model.apply(projection(running, .running))
        #expect(model.clearFinished(keepingFailures: true) == [good])
        #expect(model.hasFailures)
        #expect(model.clearFinished(keepingFailures: false) == [bad])
        #expect(model.entries.map(\.id) == [running])
    }
}
