import Foundation
import HSpaceContracts

// BatchRename pod's sole public contract surface (Axiom 3):
// Pure name processing (steps → plan) + an all-or-nothing rename engine + the journal that undoes it.
// A plan never touches the disk beyond reading it: nothing is renamed until `BatchRenamer.apply`, which refuses a plan with any blocked row.

public struct BatchRenameError: ClassifiedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String
    public let path: String?

    init(_ cls: ErrorClass, _ message: String, path: String? = nil) {
        self.errorClass = cls
        self.localizedDescription = message
        self.path = path
    }
}

// MARK: - Steps

/// Which part of a name a step works on. The extension excludes its dot.
public enum RenameScope: String, Sendable, Hashable, Codable, CaseIterable {
    case stem, fileExtension, wholeName
}

/// Where inserted text goes, always relative to the stem. `replaceName` drops the current stem.
public enum RenamePosition: String, Sendable, Hashable, Codable, CaseIterable {
    case prefix, suffix, replaceName
}

public enum NameCase: String, Sendable, Hashable, Codable, CaseIterable {
    case lower, upper, title, sentence
}

public enum DateSource: String, Sendable, Hashable, Codable, CaseIterable {
    case modified, created, now
}

public struct ReplaceStep: Sendable, Hashable, Codable {
    public var find: String
    public var replacement: String
    /// `find` is a regular expression and `replacement` may use `$1`
    public var isRegex: Bool
    public var caseSensitive: Bool
    public var firstMatchOnly: Bool
    public var scope: RenameScope

    public init(find: String, replacement: String, isRegex: Bool = false, caseSensitive: Bool = false,
                firstMatchOnly: Bool = false, scope: RenameScope = .stem) {
        self.find = find; self.replacement = replacement; self.isRegex = isRegex
        self.caseSensitive = caseSensitive; self.firstMatchOnly = firstMatchOnly; self.scope = scope
    }
}

public struct SequenceStep: Sendable, Hashable, Codable {
    public var start: Int
    public var increment: Int
    /// Minimum digits, zero padded
    public var width: Int
    public var position: RenamePosition
    public var separator: String
    /// Numbering starts over in each folder of a selection spanning several
    public var restartPerFolder: Bool

    public init(start: Int = 1, increment: Int = 1, width: Int = 1, position: RenamePosition = .suffix,
                separator: String = " ", restartPerFolder: Bool = false) {
        self.start = start; self.increment = increment; self.width = width
        self.position = position; self.separator = separator; self.restartPerFolder = restartPerFolder
    }
}

public struct DateStep: Sendable, Hashable, Codable {
    public var source: DateSource
    /// `DateFormatter` pattern. A "/" or ":" in it blocks the row: it cannot be part of a name
    public var format: String
    public var position: RenamePosition
    public var separator: String

    public init(source: DateSource = .modified, format: String = "yyyy-MM-dd",
                position: RenamePosition = .prefix, separator: String = " ") {
        self.source = source; self.format = format; self.position = position; self.separator = separator
    }
}

/// One processor of the pipeline. Codable because presets are stored steps.
public enum RenameStep: Sendable, Hashable, Codable {
    case replace(ReplaceStep)
    case changeCase(NameCase, scope: RenameScope)
    case insert(text: String, position: RenamePosition)
    case sequence(SequenceStep)
    case date(DateStep)
}

// MARK: - Plan

public struct RenameItem: Sendable, Hashable {
    public let url: URL
    public let isDirectory: Bool
    public let isPackage: Bool
    public let created: Date?
    public let modified: Date?

    public init(url: URL, isDirectory: Bool = false, isPackage: Bool = false,
                created: Date? = nil, modified: Date? = nil) {
        self.url = url; self.isDirectory = isDirectory; self.isPackage = isPackage
        self.created = created; self.modified = modified
    }

    public init(_ item: FileItem) {
        self.init(url: item.url, isDirectory: item.isDirectory, isPackage: item.isPackage,
                  created: item.created, modified: item.modified)
    }
}

/// Why a row cannot be renamed. Any one of these blocks the whole batch.
public enum RenameIssue: Sendable, Hashable {
    case emptyName
    /// Holds "/", ":" or a control character, or is "." or ".."
    case invalidName
    /// Over 255 UTF-8 bytes
    case nameTooLong
    /// Two rows end on the same name, compared as the volume compares names
    case duplicateInBatch
    /// An item outside the batch already holds the name
    case existsOnDisk
    case sourceMissing
}

public enum RenameRowStatus: Sendable, Hashable {
    case unchanged, ready
    case blocked(RenameIssue)
}

public struct RenamePlanRow: Sendable, Hashable {
    public let source: URL
    public let newName: String
    public let status: RenameRowStatus

    public var target: URL { source.deletingLastPathComponent().appendingPathComponent(newName) }
}

public struct RenamePlan: Sendable {
    public let rows: [RenamePlanRow]

    public var changeCount: Int { rows.filter { $0.status == .ready }.count }
    public var blockedCount: Int {
        rows.filter { if case .blocked = $0.status { true } else { false } }.count
    }
    public var canApply: Bool { changeCount > 0 && blockedCount == 0 }
}

public enum BatchRenamePlanner {
    /// Runs `steps` over `items`, in order (sequences number in this order), and checks the result against the disk.
    /// Throws only for steps that cannot run at all, such as an invalid regular expression.
    public static func plan(items: [RenameItem], steps: [RenameStep], now: Date = Date()) throws -> RenamePlan {
        let names = try NamePipeline(steps: steps, now: now).names(for: items)
        return checkedPlan(sources: items.map(\.url), names: names)
    }

    /// Checks explicit new names, one per source, in the same way.
    public static func plan(sources: [URL], names: [String]) throws -> RenamePlan {
        guard sources.count == names.count else {
            throw BatchRenameError(.logic, "Expected \(sources.count) names, got \(names.count).")
        }
        return checkedPlan(sources: sources, names: names)
    }

    /// Checks one new name per line of `text`, in source order. Lines are not trimmed: a space is part of a name.
    /// Blank lines after the last name are ignored, since a text box easily ends with a few.
    public static func plan(sources: [URL], text: String) throws -> RenamePlan {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        while lines.count > sources.count, lines.last?.isEmpty == true { lines.removeLast() }
        guard lines.count == sources.count else {
            throw BatchRenameError(.external, "Expected \(sources.count) lines, one per item, but found \(lines.count).")
        }
        return checkedPlan(sources: sources, names: lines)
    }
}

// MARK: - Apply and undo

public struct RenameJournalEntry: Sendable, Hashable, Codable {
    public let from: String
    public let to: String

    public init(from: String, to: String) { self.from = from; self.to = to }
}

/// What one batch really did, enough to reverse it. Paths are absolute.
public struct RenameJournal: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let date: Date
    public let entries: [RenameJournalEntry]

    public init(id: UUID = UUID(), date: Date = Date(), entries: [RenameJournalEntry]) {
        self.id = id; self.date = date; self.entries = entries
    }

    public var renamedURLs: [URL] { entries.map { URL(fileURLWithPath: $0.to) } }
}

public enum BatchRenamer {
    /// All or nothing: checks the plan against the disk again, then renames.
    /// On failure or cancellation every rename already done is reversed before this throws, so names swapped within
    /// a batch stay safe. `progress` receives (done, total) on the calling task.
    public static func apply(_ plan: RenamePlan,
                             progress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> RenameJournal {
        guard plan.blockedCount == 0 else {
            throw BatchRenameError(.logic, "The plan has blocked rows.")
        }
        let moves = plan.rows.filter { $0.status == .ready }.map { RenameMove(from: $0.source, to: $0.target) }
        return try await performChecked(moves, progress: progress)
    }

    /// Reverses a journal, as one batch and with the same guarantees. Refused, with nothing touched, when an item has
    /// moved since or something else now holds an old name. Returns the journal that reverses this undo.
    public static func undo(_ journal: RenameJournal,
                            progress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> RenameJournal {
        let moves = journal.entries.reversed().map {
            RenameMove(from: URL(fileURLWithPath: $0.to), to: URL(fileURLWithPath: $0.from))
        }
        return try await performChecked(moves, progress: progress)
    }
}
