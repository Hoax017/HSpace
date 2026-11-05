import Foundation

public enum NamePatternKind: String, Sendable, Hashable, Codable, CaseIterable {
    /// `*`, `?` and `[abc]`, the whole name must match. Several patterns separated by ";" are alternatives
    case glob
    case regex
    case contains
}

/// A rule for picking items by name. Pure: it never looks at the disk.
public struct NamePattern {
    private let regexes: [NSRegularExpression]

    /// An empty pattern matches nothing. An invalid regular expression throws.
    public init(_ text: String, kind: NamePatternKind, caseSensitive: Bool = false) throws {
        let sources: [String]
        switch kind {
        case .glob:
            sources = text.split(separator: ";")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map(Self.regexSource(forGlob:))
        case .regex:
            sources = text.isEmpty ? [] : [text]
        case .contains:
            sources = text.isEmpty ? [] : [NSRegularExpression.escapedPattern(for: text)]
        }
        let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        do {
            regexes = try sources.map { try NSRegularExpression(pattern: $0, options: options) }
        } catch {
            throw BatchRenameError(.external, "Not a valid regular expression: \(text)")
        }
    }

    public func matches(_ name: String) -> Bool {
        let whole = NSRange(name.startIndex..., in: name)
        return regexes.contains { $0.firstMatch(in: name, range: whole) != nil }
    }

    /// `[!a]` negates a set, as in the shell. An unclosed `[` is a plain character.
    private static func regexSource(forGlob glob: String) -> String {
        var source = "^"
        var rest = Substring(glob)
        while let character = rest.popFirst() {
            switch character {
            case "*":
                source += ".*"
            case "?":
                source += "."
            case "[":
                guard let close = rest.dropFirst().firstIndex(of: "]") else {
                    source += "\\["
                    continue
                }
                var set = String(rest[..<close])
                if set.hasPrefix("!") { set = "^" + set.dropFirst() }
                source += "[" + set.replacingOccurrences(of: "\\", with: "\\\\") + "]"
                rest = rest[rest.index(after: close)...]
            default:
                source += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        return source + "$"
    }
}
