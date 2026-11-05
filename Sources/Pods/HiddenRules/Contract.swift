import Foundation
import HSpaceContracts

// HiddenRules pod's sole public contract surface (Axiom 3): which items the owner does not want to see.
// A hide rule makes an item behave like a dot file: "show hidden files" brings it back. An exclude rule keeps it out of view always.
// Rules only change what views show. Nothing on disk changes.

public enum HiddenRuleEffect: String, Sendable, Codable, CaseIterable {
    case hide, exclude
}

public enum HiddenRuleTarget: String, Sendable, Codable, CaseIterable {
    case any, files, folders
}

public struct HiddenRule: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    /// `*`, `?` and `[a-z]`, without regard to case, against the item's name.
    /// A pattern with a `/` is matched against the full path instead.
    public var pattern: String
    public var effect: HiddenRuleEffect
    public var target: HiddenRuleTarget
    /// Only in this folder and below. nil = everywhere.
    public var scope: String?
    public var isEnabled: Bool

    public init(id: UUID = UUID(), pattern: String, effect: HiddenRuleEffect = .hide, target: HiddenRuleTarget = .any,
                scope: String? = nil, isEnabled: Bool = true) {
        self.id = id
        self.pattern = pattern
        self.effect = effect
        self.target = target
        self.scope = scope
        self.isEnabled = isEnabled
    }

    /// The rule for exactly this item
    public static func exact(_ url: URL, isDirectory: Bool) -> HiddenRule {
        HiddenRule(pattern: HiddenRuleSet.escaped(url.standardizedFileURL.path), target: isDirectory ? .folders : .files)
    }
}

public enum HiddenVerdict: Sendable, Equatable {
    case show, hide, exclude
}

/// Rules ready to apply. Cheap to apply to a whole listing.
public struct HiddenRuleSet: Sendable {
    private let rules: [HiddenRule]

    public init(_ rules: [HiddenRule]) {
        self.rules = rules.filter { $0.isEnabled && !$0.pattern.isEmpty }
    }

    public var isEmpty: Bool { rules.isEmpty }

    /// Exclude beats hide, whatever the order of the rules
    public func verdict(path: String, isFolder: Bool) -> HiddenVerdict {
        var result = HiddenVerdict.show
        for rule in rules where Self.applies(rule, path: path, isFolder: isFolder) {
            if rule.effect == .exclude { return .exclude }
            result = .hide
        }
        return result
    }

    private static func applies(_ rule: HiddenRule, path: String, isFolder: Bool) -> Bool {
        switch rule.target {
        case .any: break
        case .files: if isFolder { return false }
        case .folders: if !isFolder { return false }
        }
        if let scope = rule.scope {
            let root = scope.hasSuffix("/") ? scope : scope + "/"
            guard path.hasPrefix(root) else { return false }
        }
        let subject = rule.pattern.contains("/") ? path : (path as NSString).lastPathComponent
        return fnmatch(rule.pattern, subject, FNM_CASEFOLD) == 0
    }

    /// `text` as a pattern that matches only itself
    public static func escaped(_ text: String) -> String {
        var out = ""
        for character in text {
            if "*?[]\\".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }
}

public struct HiddenRuleError: ClassifiedError, LocalizedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String
    public var errorDescription: String? { localizedDescription }

    init(_ cls: ErrorClass, _ message: String) {
        self.errorClass = cls
        self.localizedDescription = message
    }
}

public protocol HiddenRuleStoring: Sendable {
    func rules() -> [HiddenRule]
    /// Replaces the whole list. A rule without a pattern is refused.
    func save(_ rules: [HiddenRule]) throws
    /// Hands over, once, a failure at load that no call could throw
    func takeProblem() -> HiddenRuleError?
}
