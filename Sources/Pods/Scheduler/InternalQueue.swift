import Foundation

/// The scheduling rules, free of threads and observers.
struct QueueState {
    struct Job {
        let request: SchedulerRequest
        let order: Int
        var priority: SchedulerPriority
        var running = false
        var held = false
        var withdrawn = false
    }

    var jobs: [UUID: Job] = [:]
    var isPaused = false
    var maxConcurrent: Int
    private var nextOrder = 0

    init(maxConcurrent: Int) { self.maxConcurrent = max(1, maxConcurrent) }

    mutating func enqueue(_ request: SchedulerRequest) {
        jobs[request.id] = Job(request: request, order: nextOrder, priority: request.priority)
        nextOrder += 1
    }

    private var queue: [Job] {
        jobs.values.filter { !$0.running }.sorted {
            $0.priority != $1.priority ? $0.priority > $1.priority : $0.order < $1.order
        }
    }

    private var running: [Job] { jobs.values.filter(\.running).sorted { $0.order < $1.order } }

    private func isStopped(_ job: Job) -> Bool {
        !job.withdrawn && (job.held || isPaused) && job.request.pausableWhileRunning
    }

    /// Walks the queue in start order. A job that cannot start still reserves its paths, so a later job cannot pass it.
    /// A job the user paused reserves nothing: it could otherwise stall the queue for as long as they like.
    private func walk(_ visit: (Job, _ waitsForPath: Bool) -> Void) {
        var table = LockTable()
        for job in running { table.add(job.request.claims) }
        for job in queue where !job.held {
            visit(job, table.conflicts(with: job.request.claims))
            table.add(job.request.claims)
        }
    }

    mutating func takeRunnable() -> [UUID] {
        guard !isPaused else { return [] }
        var slots = maxConcurrent - running.filter { !isStopped($0) }.count
        var started: [UUID] = []
        walk { job, waits in
            guard slots > 0, !waits else { return }
            slots -= 1
            started.append(job.request.id)
        }
        for id in started { jobs[id]?.running = true }
        return started
    }

    func snapshot() -> SchedulerSnapshot {
        var waiting: Set<UUID> = []
        walk { job, waits in
            if waits { waiting.insert(job.request.id) }
        }
        let statuses = (running + queue).map { job -> SchedulerJobStatus in
            let phase: SchedulerPhase
            if job.running {
                phase = isStopped(job) ? .paused : .running
            } else if job.held {
                phase = .paused
            } else {
                phase = waiting.contains(job.request.id) ? .waitingForPath : .queued
            }
            return SchedulerJobStatus(id: job.request.id, priority: job.priority, phase: phase,
                                      canPause: !job.running || job.request.pausableWhileRunning)
        }
        return SchedulerSnapshot(jobs: statuses, isPaused: isPaused, maxConcurrent: maxConcurrent)
    }

    func mustWait(_ id: UUID) -> Bool {
        guard let job = jobs[id], job.running else { return false }
        return isStopped(job)
    }
}
