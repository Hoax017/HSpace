import Foundation
import HSpaceContracts
import Scheduler

/// What a row in the task window shows, derived from the kernel's run state and the scheduler's job state.
enum TaskPhase: Equatable {
    case queued, waitingForPath, paused, active, finished
}

struct TaskEntry: Equatable {
    let id: UUID
    let phase: TaskPhase
    let priority: SchedulerPriority?
    let canPause: Bool
}

/// The toolbar's one-glance view of the queue.
struct TaskStatusSummary: Equatable {
    var running = 0
    var waiting = 0
    var paused = 0
    /// Share of the bytes done across unfinished tasks; nil when no task knows its size yet
    var fraction: Double?

    var unfinished: Int { running + waiting + paused }

    /// Toolbar tooltip and VoiceOver value
    var text: String {
        guard unfinished > 0 else { return L10n.t("tasks.status.idle") }
        var parts: [String] = []
        if running > 0 { parts.append(L10n.f("tasks.status.running", running)) }
        if waiting > 0 { parts.append(L10n.f("tasks.status.waiting", waiting)) }
        if paused > 0 { parts.append(L10n.f("tasks.status.paused", paused)) }
        let list = parts.joined(separator: ", ")
        return fraction.map { L10n.f("tasks.status.withPercent", list, Int($0 * 100)) } ?? list
    }
}

/// Merges the two streams. Either can arrive first, and each can lag the other, so nothing here assumes an order.
struct TaskListModel {
    private(set) var projections: [UUID: OperationProjection] = [:]
    private var arrival: [UUID] = []
    private var schedule: SchedulerSnapshot?

    var isQueuePaused: Bool { schedule?.isPaused == true }

    var hasUnfinished: Bool { projections.values.contains { !$0.state.isTerminal } }

    var hasFailures: Bool {
        projections.values.contains {
            if case .failed = $0.state { return true }
            return false
        }
    }

    mutating func apply(_ projection: OperationProjection) {
        if projections.updateValue(projection, forKey: projection.id) == nil { arrival.append(projection.id) }
    }

    mutating func apply(_ snapshot: SchedulerSnapshot) { schedule = snapshot }

    /// Scheduler order for what is not finished, then what is finished in arrival order.
    var entries: [TaskEntry] {
        let scheduled = (schedule?.jobs ?? []).map(\.id).filter { projections[$0]?.state.isTerminal == false }
        let known = Set(scheduled)
        return (scheduled + arrival.filter { !known.contains($0) }).compactMap(entry)
    }

    private func entry(_ id: UUID) -> TaskEntry? {
        guard let projection = projections[id] else { return nil }
        guard !projection.state.isTerminal else {
            return TaskEntry(id: id, phase: .finished, priority: nil, canPause: false)
        }
        guard let job = schedule?.status(of: id) else {
            return TaskEntry(id: id, phase: projection.state == .pending ? .queued : .active, priority: nil, canPause: false)
        }
        let phase: TaskPhase = switch job.phase {
        case .queued: .queued
        case .waitingForPath: .waitingForPath
        case .paused: .paused
        case .running: .active
        }
        return TaskEntry(id: id, phase: phase, priority: job.priority, canPause: job.canPause)
    }

    var summary: TaskStatusSummary {
        var summary = TaskStatusSummary()
        var done: Int64 = 0, total: Int64 = 0
        for entry in entries where entry.phase != .finished {
            switch entry.phase {
            case .active: summary.running += 1
            case .paused: summary.paused += 1
            default: summary.waiting += 1
            }
            if let projection = projections[entry.id], projection.bytesTotal > 0 {
                done += projection.bytesDone
                total += projection.bytesTotal
            }
        }
        summary.fraction = total > 0 ? min(1, Double(done) / Double(total)) : nil
        return summary
    }

    /// Removes finished tasks. Automatic clearing keeps failures, which the user has to see.
    @discardableResult
    mutating func clearFinished(keepingFailures: Bool) -> [UUID] {
        let removed = projections.values.filter { projection in
            guard projection.state.isTerminal else { return false }
            if keepingFailures, case .failed = projection.state { return false }
            return true
        }.map(\.id)
        for id in removed { projections[id] = nil }
        arrival.removeAll { projections[$0] == nil }
        return removed
    }
}
