import Foundation
import HSpaceContracts

// FileMetadata pod's sole public contract surface (Axiom 3): metadata the OS and Finder own, kept in the places they read it from.
// Tags live in the `com.apple.metadata:_kMDItemUserTags` attribute plus the label bits of `com.apple.FinderInfo`, which is
// exactly what macOS writes itself: a file tagged here shows the same tags in Finder, and the other way round.
// Comments live in `com.apple.metadata:kMDItemFinderComment`, which is what Spotlight and `mdls` read. Finder's Get Info
// shows its own copy from the folder's .DS_Store, which only Finder can write, so `FinderCommentPushing` asks Finder to update it.

/// Finder's seven tag colours. The raw value is the number stored after the tag name, and the Finder label number.
public enum TagColor: Int, Sendable, Codable, CaseIterable {
    case none = 0, gray, green, purple, blue, yellow, red, orange
}

/// One Finder tag. Finder treats names without regard to case; use `TagQuery` to compare them.
public struct FinderTag: Sendable, Hashable, Codable {
    public let name: String
    public let color: TagColor

    public init(name: String, color: TagColor = .none) {
        self.name = name
        self.color = color
    }

    /// The tags every Mac starts with, in Finder's menu order
    public static let standard: [FinderTag] = [
        FinderTag(name: "Red", color: .red), FinderTag(name: "Orange", color: .orange),
        FinderTag(name: "Yellow", color: .yellow), FinderTag(name: "Green", color: .green),
        FinderTag(name: "Blue", color: .blue), FinderTag(name: "Purple", color: .purple),
        FinderTag(name: "Gray", color: .gray),
    ]
}

public struct MetadataError: ClassifiedError, LocalizedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String
    /// What `localizedDescription` gives on `any Error`, which is how the app receives it
    public var errorDescription: String? { localizedDescription }

    init(_ cls: ErrorClass, _ message: String) {
        self.errorClass = cls
        self.localizedDescription = message
    }
}

/// What the pod knows about one item
public struct ItemMetadata: Sendable, Hashable {
    public var tags: [FinderTag]
    public var comment: String?

    public init(tags: [FinderTag] = [], comment: String? = nil) {
        self.tags = tags
        self.comment = comment
    }
}

/// A change to apply to every item of a batch
public enum MetadataEdit: Sendable {
    /// Keeps the item's other tags. `remove` holds names, compared without regard to case.
    case tags(add: [FinderTag], remove: Set<String>)
    /// Replaces the comment. nil or empty removes it.
    case comment(String?)
}

/// One stored value, as it was before a change. Giving it back to `restore` undoes the change.
public enum MetadataValue: Sendable, Hashable {
    case tags([FinderTag])
    case comment(String?)
}

public struct MetadataChange: Sendable, Hashable {
    public let url: URL
    public let before: MetadataValue

    public init(url: URL, before: MetadataValue) {
        self.url = url
        self.before = before
    }
}

/// What a batch really did. Items that already had the wanted value are in neither list.
public struct MetadataBatchResult: Sendable {
    /// What changed, for undo
    public let changed: [MetadataChange]
    public let failures: [OperationFailure]

    public init(changed: [MetadataChange], failures: [OperationFailure]) {
        self.changed = changed
        self.failures = failures
    }
}

public typealias MetadataProgress = @Sendable (_ done: Int, _ total: Int) -> Void

/// Tells Finder about a comment, so its Get Info window shows it too. Behind a protocol because the real one sends Apple
/// Events to Finder, and that needs the user's consent, which tests must not ask for.
public protocol FinderCommentPushing: Sendable {
    /// `comment` is empty to clear it. Throws `MetadataError` when Finder could not be told.
    func push(comment: String, to urls: [URL]) async throws
}

/// Pure rules for tag lists. No file access.
public enum TagQuery {
    public static func sameName(_ a: String, _ b: String) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedSame
    }

    /// True when the item has at least one of the names
    public static func matches(_ tags: [FinderTag], anyOf names: Set<String>) -> Bool {
        tags.contains { tag in names.contains { sameName($0, tag.name) } }
    }

    /// Removes `remove`, then appends what is new in `add`. Tags already there keep their place and colour.
    public static func merged(_ tags: [FinderTag], add: [FinderTag], remove: Set<String>) -> [FinderTag] {
        var result = tags.filter { !matches([$0], anyOf: remove) }
        for tag in add where !result.contains(where: { sameName($0.name, tag.name) }) {
            result.append(tag)
        }
        return result
    }

    /// Every tag in use, one per name, sorted by name
    public static func known(in lists: some Sequence<[FinderTag]>) -> [FinderTag] {
        var seen: [String: FinderTag] = [:]
        for tag in lists.joined() {
            let key = tag.name.lowercased()
            // A coloured spelling of a tag beats an uncoloured one
            if seen[key] == nil || seen[key]?.color == TagColor.none { seen[key] = tag }
        }
        return seen.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Groups equally tagged items, keeping their order. Items without tags stay last in both directions.
    public static func sorted<T>(_ items: [T], ascending: Bool, tags: (T) -> [FinderTag]) -> [T] {
        let keyed = items.enumerated().map { (offset: $0.offset, item: $0.element, key: sortKey(tags($0.element))) }
        return keyed.sorted { a, b in
            if a.key.isEmpty != b.key.isEmpty { return b.key.isEmpty }
            let order = a.key.localizedStandardCompare(b.key)
            if order == .orderedSame { return a.offset < b.offset }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }.map(\.item)
    }

    private static func sortKey(_ tags: [FinderTag]) -> String {
        tags.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }.joined(separator: "\n")
    }
}
