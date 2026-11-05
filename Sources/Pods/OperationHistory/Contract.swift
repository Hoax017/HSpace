import Foundation
import HSpaceContracts

// OperationHistory pod's sole public contract surface (Axiom 3): what was done, across launches, and how to take it back.
// A step records a fact about what landed, never a guess. What cannot be proven reversible is recorded as `.joined`
// and is left alone by undo: a copy that merged into an existing folder must not send that folder to the Trash.
// The pod plans undo and checks the disk. The operations themselves go through the kernel like any other (BG-1).

public enum HistoryStep: Sendable, Hashable, Codable {
    /// A new item that was not there before
    case created(path: String)
    /// An item moved, possibly under another name
    case moved(from: String, to: String)
    case renamed(from: String, to: String)
    case trashed(original: String, trashed: String)
    /// Landed on or into something that was already there, so taking it out would take more than it brought
    case joined(path: String)
}

public enum HistoryOutcome: Sendable, Hashable, Codable {
    case completed, cancelled
    /// Some or all of it failed. The steps hold what landed.
    case failed(String)
}

public struct HistoryEntry: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    /// Entries sharing a group are one action for the user, and undo as one
    public let groupID: UUID
    /// Name of a multi-operation action; nil for a plain operation
    public let groupTitle: String?
    public let date: Date
    /// `OperationSpec.Kind` raw value
    public let kind: String
    /// Sample of the items acted on, for display
    public let names: [String]
    public let itemCount: Int
    public let steps: [HistoryStep]
    public let outcome: HistoryOutcome

    public init(id: UUID = UUID(), groupID: UUID? = nil, groupTitle: String? = nil, date: Date = Date(), kind: String,
                names: [String], itemCount: Int, steps: [HistoryStep], outcome: HistoryOutcome) {
        self.id = id
        self.groupID = groupID ?? id
        self.groupTitle = groupTitle
        self.date = date
        self.kind = kind
        self.names = names
        self.itemCount = itemCount
        self.steps = steps
        self.outcome = outcome
    }
}

/// One line of the history: the entries of one action, oldest first.
public struct HistoryGroup: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let entries: [HistoryEntry]
    public let isUndone: Bool

    public init(id: UUID, entries: [HistoryEntry], isUndone: Bool) {
        self.id = id
        self.entries = entries
        self.isUndone = isUndone
    }

    public var date: Date { entries.last?.date ?? .distantPast }
    public var title: String? { entries.first?.groupTitle }
    public var itemCount: Int { entries.reduce(0) { $0 + $1.itemCount } }
    public var steps: [HistoryStep] { entries.flatMap(\.steps) }

    /// First failure message, if any part failed
    public var failure: String? {
        for entry in entries { if case .failed(let message) = entry.outcome { return message } }
        return nil
    }

    public var wasCancelled: Bool { entries.contains { $0.outcome == .cancelled } }

    public var canUndo: Bool {
        !isUndone && steps.contains {
            if case .joined = $0 { return false }
            return true
        }
    }
}

public struct HistoryError: ClassifiedError, LocalizedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String
    public var errorDescription: String? { localizedDescription }

    init(_ cls: ErrorClass, _ message: String) {
        self.errorClass = cls
        self.localizedDescription = message
    }
}

// MARK: Turning a finished operation into steps

public enum HistoryBuilder {
    /// Whether anything is at this path, counting a dangling link as present
    static func occupied(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// Sample before the run: which targets of a copy or move are already taken. Afterwards the receipt cannot tell a new item from a merge.
    public static func occupiedTargets(of spec: OperationSpec) -> Set<String> {
        guard [.copy, .move].contains(spec.kind), let destination = spec.destination else { return [] }
        let name = spec.sources.count == 1 ? spec.newName : nil
        let paths = spec.sources.map { destination.appendingPathComponent(name ?? $0.lastPathComponent).path }
        return Set(paths.filter(occupied))
    }

    public static func steps(of spec: OperationSpec, receipt: OperationReceipt,
                             occupiedBefore: Set<String>, startedAt: Date) -> [HistoryStep] {
        let created = receipt.createdURLs.map(\.path)
        switch spec.kind {
        case .copy:
            return created.map { occupiedBefore.contains($0) ? .joined(path: $0) : .created(path: $0) }
        case .duplicate, .newFile, .newFolder, .compress:
            return created.map { .created(path: $0) }
        case .extract:
            return created.map { isNew($0, since: startedAt) ? .created(path: $0) : .joined(path: $0) }
        case .move:
            return moveSteps(spec, created: created, occupiedBefore: occupiedBefore)
        case .rename:
            guard let source = spec.sources.first, let target = created.first, source.path != target else { return [] }
            return [.renamed(from: source.path, to: target)]
        case .trash:
            return receipt.trashedItems.map { .trashed(original: $0.original.path, trashed: $0.trashed.path) }
        case .delete:
            return []
        }
    }

    /// The receipt lists destinations in source order without the skipped sources, and a skipped source is still in place.
    private static func moveSteps(_ spec: OperationSpec, created: [String], occupiedBefore: Set<String>) -> [HistoryStep] {
        var remaining = created[...]
        var steps: [HistoryStep] = []
        for source in spec.sources where !occupied(source.path) {
            guard let target = remaining.popFirst() else { break }
            steps.append(occupiedBefore.contains(target) ? .joined(path: target) : .moved(from: source.path, to: target))
        }
        return steps
    }

    /// An archive tool writes new items, so a birth date before the run marks one that was already there.
    private static func isNew(_ path: String, since start: Date) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return Double(info.st_birthtimespec.tv_sec) >= start.timeIntervalSince1970.rounded(.down)
    }
}

// MARK: Planning an undo

public enum HistoryUndoAction: Sendable, Equatable {
    /// To the Trash, so that an undo is itself recoverable
    case discard(URL)
    /// Back to `original`. `original`'s name can differ from the current one.
    case moveBack(current: URL, original: URL)
    case renameBack(current: URL, originalName: String)
    case restore(TrashedItem)
}

public enum HistoryUndoBlocker: Sendable, Equatable {
    /// The item is no longer where the operation left it
    case missing(String)
    /// Its original place is taken
    case occupied(String)
}

public struct HistoryUndoPlan: Sendable, Equatable {
    /// Newest first: the reverse of how the action happened
    public let actions: [HistoryUndoAction]
    public let blockers: [HistoryUndoBlocker]
    /// Items that joined something existing, which undo leaves where they are
    public let leftInPlace: Int
    /// Items already gone, which need nothing
    public let alreadyGone: Int
}

public enum HistoryUndoPlanner {
    public static func plan(_ group: HistoryGroup) -> HistoryUndoPlan {
        var actions: [HistoryUndoAction] = []
        var blockers: [HistoryUndoBlocker] = []
        var leftInPlace = 0, alreadyGone = 0
        for step in group.steps.reversed() {
            switch step {
            case .created(let path):
                if HistoryBuilder.occupied(path) {
                    actions.append(.discard(URL(fileURLWithPath: path)))
                } else {
                    alreadyGone += 1
                }
            case .moved(let from, let to):
                let origin = URL(fileURLWithPath: from), current = URL(fileURLWithPath: to)
                if !HistoryBuilder.occupied(to) {
                    blockers.append(.missing(to))
                } else if HistoryBuilder.occupied(from) {
                    blockers.append(.occupied(from))
                } else if current.lastPathComponent != origin.lastPathComponent,
                          HistoryBuilder.occupied(origin.deletingLastPathComponent().appendingPathComponent(current.lastPathComponent).path) {
                    blockers.append(.occupied(origin.deletingLastPathComponent().appendingPathComponent(current.lastPathComponent).path))
                } else {
                    actions.append(.moveBack(current: current, original: origin))
                }
            case .renamed(let from, let to):
                if !HistoryBuilder.occupied(to) {
                    blockers.append(.missing(to))
                } else if HistoryBuilder.occupied(from), !isSameItem(from, to) {
                    blockers.append(.occupied(from))
                } else {
                    actions.append(.renameBack(current: URL(fileURLWithPath: to),
                                               originalName: URL(fileURLWithPath: from).lastPathComponent))
                }
            case .trashed(let original, let trashed):
                if HistoryBuilder.occupied(trashed) {
                    actions.append(.restore(TrashedItem(original: URL(fileURLWithPath: original),
                                                        trashed: URL(fileURLWithPath: trashed))))
                } else {
                    blockers.append(.missing(trashed))
                }
            case .joined:
                leftInPlace += 1
            }
        }
        return HistoryUndoPlan(actions: actions, blockers: blockers, leftInPlace: leftInPlace, alreadyGone: alreadyGone)
    }

    /// A case-only rename: both spellings reach one item on a case-insensitive volume.
    private static func isSameItem(_ a: String, _ b: String) -> Bool {
        var first = stat(), second = stat()
        guard lstat(a, &first) == 0, lstat(b, &second) == 0 else { return false }
        return first.st_ino == second.st_ino && first.st_dev == second.st_dev
    }
}
