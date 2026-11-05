import Foundation
import HSpaceContracts

// Scheduler pod's sole public contract surface (Axiom 3): decides which operation may start, and when.
// It never touches a file. The kernel still runs the operations: this pod answers "who is next" and "must this one wait".
//
// Order: higher priority first, first come first served within a priority.
// A queued job never overtakes an earlier job it conflicts with, so "copy here, then rename it" keeps its order.
// Locks are per path and cover the whole subtree. Reads share, a write excludes everyone, and overlapping paths conflict
// whichever of the two is the parent.

public enum SchedulerPriority: Int, Sendable, Codable, CaseIterable, Comparable {
    case low = 0, normal, high

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Quick edits should not sit behind a long copy.
    public static func `default`(for kind: OperationSpec.Kind) -> SchedulerPriority {
        switch kind {
        case .rename, .newFolder, .newFile: .high
        default: .normal
        }
    }
}

/// The paths an operation reads and writes, in comparable form.
public struct PathClaims: Sendable, Equatable {
    public let reads: Set<String>
    public let writes: Set<String>

    public init(reads: [URL] = [], writes: [URL] = []) {
        self.reads = Set(reads.map(LockPath.key))
        self.writes = Set(writes.map(LockPath.key))
    }

    /// What a kind of operation touches. A destination folder is locked whole: Transfer and ArchiveEngine pick
    /// unique names and sweep leftovers there, which two operations must not do at once.
    public init(spec: OperationSpec) {
        let parents = spec.sources.map { $0.deletingLastPathComponent() }
        let destination = spec.destination.map { [$0] } ?? []
        switch spec.kind {
        case .copy:
            self.init(reads: spec.sources, writes: destination)
        case .duplicate:
            self.init(reads: spec.sources, writes: parents)
        case .move:
            self.init(writes: spec.sources + destination)
        case .trash, .delete:
            self.init(writes: spec.sources)
        case .rename:
            let targets = spec.newName.map { name in parents.map { $0.appendingPathComponent(name) } } ?? []
            self.init(writes: spec.sources + targets)
        case .newFolder, .newFile:
            let named = spec.newName.map { name in destination.map { $0.appendingPathComponent(name) } }
            self.init(writes: named ?? destination)
        case .compress:
            self.init(reads: spec.sources, writes: destination.isEmpty ? parents : destination)
        case .extract:
            let into = spec.archiveOptions?.extractInto.map { [$0] }
            self.init(reads: spec.sources, writes: into ?? (destination.isEmpty ? parents : destination))
        }
    }

    public func conflicts(with other: PathClaims) -> Bool {
        var table = LockTable()
        table.add(other)
        return table.conflicts(with: self)
    }
}

/// One operation asking to run
public struct SchedulerRequest: Sendable {
    public let id: UUID
    public let priority: SchedulerPriority
    public let claims: PathClaims
    /// Whether the node stops at `waitWhilePaused` once running. Others can only be paused before they start.
    public let pausableWhileRunning: Bool

    public init(id: UUID, priority: SchedulerPriority = .normal, claims: PathClaims = PathClaims(),
                pausableWhileRunning: Bool = false) {
        self.id = id
        self.priority = priority
        self.claims = claims
        self.pausableWhileRunning = pausableWhileRunning
    }

    public init(id: UUID, spec: OperationSpec) {
        self.init(id: id, priority: .default(for: spec.kind), claims: PathClaims(spec: spec),
                  pausableWhileRunning: [.copy, .move, .duplicate].contains(spec.kind))
    }
}

public enum SchedulerPhase: Sendable, Equatable {
    /// Waiting for a free slot or for the queue to resume
    case queued
    /// Waiting because an earlier job holds or will hold one of its paths
    case waitingForPath
    case running
    /// Stopped by the user, either before starting or at the node's next stopping point. A paused running job keeps its locks.
    case paused
}

public struct SchedulerJobStatus: Sendable, Equatable {
    public let id: UUID
    public let priority: SchedulerPriority
    public let phase: SchedulerPhase
    /// Whether Pause can apply now
    public let canPause: Bool
}

/// Unfinished jobs: those running first, then the queue in the order it will start.
public struct SchedulerSnapshot: Sendable, Equatable {
    public let jobs: [SchedulerJobStatus]
    public let isPaused: Bool
    public let maxConcurrent: Int

    public func status(of id: UUID) -> SchedulerJobStatus? { jobs.first { $0.id == id } }
}
