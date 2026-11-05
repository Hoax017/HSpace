import Foundation

/// Carries out a plan through a driver, checking the disk before each step.
public enum SyncExecutor {
    /// `progress` gets (done, total) actions. Ends early on the first failure and on cancellation: copies come first,
    /// so a failed copy keeps the deletes from running.
    public static func run(_ plan: SyncPlan, mode: SyncMode, driver: SyncDriver,
                           progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async -> SyncReport {
        var run = Execution(plan: plan, mode: mode, driver: driver, progress: progress)
        await run.go()
        return run.report
    }
}

private struct Execution {
    let plan: SyncPlan
    let mode: SyncMode
    let driver: SyncDriver
    let progress: @Sendable (Int, Int) -> Void
    var report = SyncReport()
    private var done = 0
    private let total: Int

    init(plan: SyncPlan, mode: SyncMode, driver: SyncDriver, progress: @escaping @Sendable (Int, Int) -> Void) {
        self.plan = plan
        self.mode = mode
        self.driver = driver
        self.progress = progress
        total = plan.actions.count - plan.skipped.count
        report.isDryRun = mode == .dryRun
    }

    private var writes: Bool { mode != .dryRun }

    private var deletesAllowed: Bool {
        switch mode {
        case .dryRun, .apply(confirmedDeletes: true): true
        case .apply(confirmedDeletes: false): false
        }
    }

    mutating func go() async {
        await createFolders()
        await batches(.copy)
        await batches(.replace)
        if deletesAllowed {
            await batches(.delete)
        } else {
            report.unconfirmedDeletes = plan.deletes.count
        }
    }

    private var isStopped: Bool { report.wasCancelled || report.stoppedEarly }

    private mutating func createFolders() async {
        for action in plan.actions.filter({ $0.kind == .createFolder }) where !isStopped {
            guard isCurrent(action) else { continue }
            await attempt([action]) { driver in
                try await driver.makeFolder(action.target.lastPathComponent, action.target.deletingLastPathComponent())
            }
        }
    }

    /// Neighbouring actions into one folder go as one operation, so that a thousand files are one task and not a thousand.
    private mutating func batches(_ kind: SyncAction.Kind) async {
        var pending = plan.actions.filter { $0.kind == kind }[...]
        while let first = pending.first, !isStopped {
            let folder = first.target.deletingLastPathComponent()
            let batch = pending.prefix { $0.target.deletingLastPathComponent() == folder }
            pending = pending.dropFirst(batch.count)
            let current = batch.filter { isCurrent($0) }
            guard !current.isEmpty else { continue }
            await attempt(current) { driver in
                if kind == .delete || kind == .replace { try await driver.trash(current.map(\.target)) }
                if kind != .delete { try await driver.copy(current.compactMap(\.source), folder) }
            }
        }
    }

    /// The plan's picture of this action still holds. A folder made earlier in this run is the plan coming true, not a change.
    private mutating func isCurrent(_ action: SyncAction) -> Bool {
        let holds: Bool
        switch action.kind {
        case .createFolder:
            holds = !Disk.exists(action.target)
        case .copy:
            holds = sourceHolds(action) && !Disk.exists(action.target)
        case .replace:
            holds = sourceHolds(action) && action.targetMark == Disk.mark(of: action.target)
        case .delete:
            holds = action.targetMark == Disk.mark(of: action.target)
        case .skip:
            holds = false
        }
        if !holds {
            report.changedSincePreview.append(action.relativePath)
            advance(by: 1)
        }
        return holds
    }

    private func sourceHolds(_ action: SyncAction) -> Bool {
        guard let source = action.source else { return false }
        return action.sourceMark == Disk.mark(of: source)
    }

    private mutating func attempt(_ actions: [SyncAction], _ body: (SyncDriver) async throws -> Void) async {
        do {
            try Task.checkCancellation()
            if writes { try await body(driver) }
            count(actions)
            advance(by: actions.count)
        } catch is CancellationError {
            report.wasCancelled = true
        } catch {
            report.failures.append(SyncProblem(path: actions[0].relativePath, message: error.localizedDescription))
            report.stoppedEarly = true
        }
    }

    private mutating func count(_ actions: [SyncAction]) {
        for action in actions {
            switch action.kind {
            case .createFolder: report.foldersCreated += 1
            case .copy: report.copied += 1; report.bytesCopied += action.bytes
            case .replace: report.replaced += 1; report.bytesCopied += action.bytes
            case .delete: report.deleted += 1
            case .skip: break
            }
        }
    }

    private mutating func advance(by count: Int) {
        done += count
        progress(done, total)
    }
}
