import Foundation
import HSpaceContracts

/// A colour for a file's name. Unlike tags these are HSpace's own, so more shades are fine and Finder never sees them.
public enum FileColor: String, Sendable, Codable, CaseIterable {
    case red, orange, yellow, green, teal, blue, purple, pink, gray
}

/// What a rule looks at. One condition per rule: several rules cover "or", and first match wins.
public enum RuleCondition: Sendable, Hashable, Codable {
    /// Without regard to case
    case nameContains(String)
    /// Extensions without the dot, without regard to case
    case fileExtension([String])
    case hasTag(String)
    case isFolder
    /// Changed in the last so many days
    case modifiedWithin(days: Int)
}

public struct ColorRule: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public var enabled: Bool
    public var color: FileColor
    public var condition: RuleCondition

    public init(id: UUID = UUID(), enabled: Bool = true, color: FileColor, condition: RuleCondition) {
        self.id = id
        self.enabled = enabled
        self.color = color
        self.condition = condition
    }
}

/// Decides a name's colour. Pure, and cheap enough for the cell path: it runs only for rows on screen.
public enum ColorRules {
    /// A colour set on the item itself beats every rule. Rules apply in order and the first match wins.
    public static func color(for item: FileItem, metadata: ItemMetadata?, rules: [ColorRule], now: Date) -> FileColor? {
        if let own = metadata?.color { return own }
        return rules.first { $0.enabled && matches($0.condition, item: item, metadata: metadata, now: now) }?.color
    }

    static func matches(_ condition: RuleCondition, item: FileItem, metadata: ItemMetadata?, now: Date) -> Bool {
        switch condition {
        case .nameContains(let text):
            return !text.isEmpty && item.name.range(of: text, options: .caseInsensitive) != nil
        case .fileExtension(let extensions):
            let own = (item.name as NSString).pathExtension
            return !own.isEmpty && !item.isDirectory
                && extensions.contains { $0.caseInsensitiveCompare(own) == .orderedSame }
        case .hasTag(let name):
            return TagQuery.matches(metadata?.tags ?? [], anyOf: [name])
        case .isFolder:
            return item.isDirectory && !item.isPackage
        case .modifiedWithin(let days):
            guard let modified = item.modified else { return false }
            return now.timeIntervalSince(modified) <= TimeInterval(days) * 86_400
        }
    }
}
