import Foundation

// Private concern: turning a name into a new name. No disk access.

/// A name split the way the steps see it. A plain folder has no extension: "v1.2" is a whole name there.
struct NameParts {
    var stem: String
    var fileExtension: String

    init(name: String, splitsExtension: Bool) {
        let ext = splitsExtension ? (name as NSString).pathExtension : ""
        fileExtension = ext
        stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
    }

    var joined: String { fileExtension.isEmpty ? stem : stem + "." + fileExtension }
}

private struct ReplaceRule {
    let step: ReplaceStep
    let regex: NSRegularExpression
    let template: String

    func callAsFunction(_ text: String) -> String {
        let whole = NSRange(text.startIndex..., in: text)
        guard step.firstMatchOnly else {
            return regex.stringByReplacingMatches(in: text, range: whole, withTemplate: template)
        }
        guard let hit = regex.firstMatch(in: text, range: whole) else { return text }
        let insert = regex.replacementString(for: hit, in: text, offset: 0, template: template)
        return (text as NSString).replacingCharacters(in: hit.range, with: insert)
    }
}

/// Steps with their regular expressions and date formatters built once, since a preview runs them for every item on every keystroke.
struct NamePipeline {
    private enum Stage {
        case replace(ReplaceRule)
        case passThrough
        case changeCase(NameCase, RenameScope)
        case text(TextProcess, RenameScope)
        case insert(String, RenamePosition)
        case sequence(SequenceStep)
        case date(DateStep, DateFormatter)
    }

    private let stages: [Stage]
    private let now: Date

    init(steps: [RenameStep], now: Date) throws {
        self.now = now
        stages = try steps.map { step in
            switch step {
            case .replace(let replace):
                guard !replace.find.isEmpty else { return .passThrough }
                return .replace(try Self.rule(for: replace))
            case .changeCase(let nameCase, let scope):
                return .changeCase(nameCase, scope)
            case .text(let process, let scope):
                return .text(process, scope)
            case .insert(let text, let position):
                return .insert(text, position)
            case .sequence(let sequence):
                return .sequence(sequence)
            case .date(let date):
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = date.format
                return .date(date, formatter)
            }
        }
    }

    private static func rule(for step: ReplaceStep) throws -> ReplaceRule {
        let pattern = step.isRegex ? step.find : NSRegularExpression.escapedPattern(for: step.find)
        let template = step.isRegex ? step.replacement : NSRegularExpression.escapedTemplate(for: step.replacement)
        do {
            let regex = try NSRegularExpression(pattern: pattern, options: step.caseSensitive ? [] : [.caseInsensitive])
            return ReplaceRule(step: step, regex: regex, template: template)
        } catch {
            throw BatchRenameError(.external, "Not a valid regular expression: \(step.find)")
        }
    }

    func names(for items: [RenameItem]) -> [String] {
        var perFolder: [URL: Int] = [:]
        return items.enumerated().map { index, item in
            let folder = item.url.deletingLastPathComponent()
            let folderIndex = perFolder[folder, default: 0]
            perFolder[folder] = folderIndex + 1
            return name(for: item, index: index, folderIndex: folderIndex)
        }
    }

    private func name(for item: RenameItem, index: Int, folderIndex: Int) -> String {
        let splits = !item.isDirectory || item.isPackage
        var parts = NameParts(name: item.url.lastPathComponent, splitsExtension: splits)
        for stage in stages {
            switch stage {
            case .passThrough:
                break
            case .replace(let rule):
                Self.edit(&parts, scope: rule.step.scope, splits: splits) { rule($0) }
            case .changeCase(let nameCase, let scope):
                Self.edit(&parts, scope: scope, splits: splits) { Self.convert($0, to: nameCase) }
            case .text(let process, let scope):
                Self.edit(&parts, scope: scope, splits: splits) { Self.apply(process, to: $0) }
            case .insert(let text, let position):
                Self.place(text, separator: "", position, in: &parts)
            case .sequence(let step):
                let count = step.restartPerFolder ? folderIndex : index
                Self.place(Self.number(step.start + count * step.increment, width: step.width),
                           separator: step.separator, step.position, in: &parts)
            case .date(let step, let formatter):
                let date = switch step.source {
                case .modified: item.modified
                case .created: item.created
                case .now: Optional(now)
                }
                guard let date else { break }
                Self.place(formatter.string(from: date), separator: step.separator, step.position, in: &parts)
            }
        }
        return parts.joined
    }

    private static func edit(_ parts: inout NameParts, scope: RenameScope, splits: Bool,
                             _ transform: (String) -> String) {
        switch scope {
        case .stem:
            parts.stem = transform(parts.stem)
        case .fileExtension:
            parts.fileExtension = transform(parts.fileExtension)
        case .wholeName:
            parts = NameParts(name: transform(parts.joined), splitsExtension: splits)
        }
    }

    private static func place(_ text: String, separator: String, _ position: RenamePosition, in parts: inout NameParts) {
        switch position {
        case .prefix: parts.stem = text + separator + parts.stem
        case .suffix: parts.stem = parts.stem + separator + text
        case .replaceName: parts.stem = text
        }
    }

    private static func convert(_ text: String, to nameCase: NameCase) -> String {
        switch nameCase {
        case .lower: return text.lowercased()
        case .upper: return text.uppercased()
        case .title: return text.capitalized
        case .sentence:
            guard let first = text.first else { return text }
            return first.uppercased() + text.dropFirst().lowercased()
        }
    }

    private static func apply(_ process: TextProcess, to text: String) -> String {
        switch process {
        case .trimSpaces:
            return text.trimmingCharacters(in: .whitespaces)
        case .collapseSpaces:
            return text.split(separator: " ", omittingEmptySubsequences: false)
                .filter { !$0.isEmpty }.joined(separator: " ")
        case .removeAccents:
            return text.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        case .spacesToDashes:
            return text.replacingOccurrences(of: " ", with: "-")
        case .spacesToUnderscores:
            return text.replacingOccurrences(of: " ", with: "_")
        case .separatorsToSpaces:
            return text.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        case .fullWidthToHalfWidth:
            return text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        }
    }

    private static func number(_ value: Int, width: Int) -> String {
        let digits = String(abs(value))
        let padded = String(repeating: "0", count: max(0, width - digits.count)) + digits
        return value < 0 ? "-" + padded : padded
    }
}
