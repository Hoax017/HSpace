import Foundation
import HSpaceContracts

// FileTemplates pod's sole public contract surface (Axiom 3): the templates are ordinary items in one folder.
// A template's own name says what its copies are called: "Report $date(yyyy-MM-dd).md" gives "Report 2026-11-05.md".
// The pod reads the folder and works out names. The copy itself is an ordinary kernel operation (BG-1).

public enum TemplateName {
    private static let opening = "$date("
    /// What an empty `$date()` means
    public static let defaultDateFormat = "yyyy-MM-dd"

    /// Replaces each `$date(format)` with the date in that format (Unicode date patterns). Text that is not a complete
    /// token stays as written. The result is always a usable file name: separators in a date become dashes.
    public static func expand(_ name: String, date: Date = Date(), locale: Locale = .current,
                              timeZone: TimeZone = .current) -> String {
        var result = ""
        var rest = Substring(name)
        while let start = rest.range(of: opening), let end = rest[start.upperBound...].firstIndex(of: ")") {
            result += rest[..<start.lowerBound]
            result += formatted(date, String(rest[start.upperBound..<end]), locale: locale, timeZone: timeZone)
            rest = rest[rest.index(after: end)...]
        }
        return sanitized(result + rest)
    }

    private static func formatted(_ date: Date, _ format: String, locale: Locale, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = format.isEmpty ? defaultDateFormat : format
        return formatter.string(from: date)
    }

    /// A template file can hold nothing unsafe, but a date format can hold a slash or a colon.
    private static func sanitized(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespaces)
        return [".", ".."].contains(cleaned) ? "" : cleaned
    }
}

public struct FileTemplate: Sendable, Hashable, Identifiable {
    public let url: URL
    public let isFolder: Bool

    public var id: URL { url }

    /// The name a copy made now would get, before any clash is resolved
    public func displayName(date: Date = Date()) -> String {
        let name = TemplateName.expand(url.lastPathComponent, date: date)
        return name.isEmpty ? url.lastPathComponent : name
    }
}

public struct TemplateError: ClassifiedError, LocalizedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String
    public var errorDescription: String? { localizedDescription }

    init(_ cls: ErrorClass, _ message: String) {
        self.errorClass = cls
        self.localizedDescription = message
    }
}

/// The template folder. Its location is constructor-injected (Axiom 2).
public struct TemplateLibrary: Sendable {
    public let folder: URL

    public init(folder: URL) { self.folder = folder }

    /// Templates by name. Hidden items are not templates. A folder not made yet just has none; any other failure throws.
    public func templates() throws -> [FileTemplate] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch CocoaError.fileReadNoSuchFile {
            return []
        } catch {
            throw TemplateError(.external, "The templates folder could not be read: \(error.localizedDescription)")
        }
        return names.filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { name in
                let url = folder.appendingPathComponent(name)
                var isFolder: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
                return FileTemplate(url: url, isFolder: isFolder.boolValue)
            }
    }

    /// Makes the folder if needed, so that it can be opened and filled.
    public func prepareFolder() throws {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw TemplateError(.external, "The templates folder could not be created: \(error.localizedDescription)")
        }
    }

    /// The name for a new copy in `directory`, which never collides: "Report.md", "Report 2.md", and so on.
    public static func targetName(for template: FileTemplate, in directory: URL, date: Date = Date(),
                                  existsCheck: (URL) -> Bool = occupied) -> String {
        let name = template.displayName(date: date)
        guard existsCheck(directory.appendingPathComponent(name)) else { return name }
        let plain = name as NSString
        // A folder's name is all stem: "v1.2 notes" has no extension to protect
        let stem = template.isFolder ? name : plain.deletingPathExtension
        let suffix = template.isFolder || plain.pathExtension.isEmpty ? "" : "." + plain.pathExtension
        var number = 2
        while existsCheck(directory.appendingPathComponent("\(stem) \(number)\(suffix)")) { number += 1 }
        return "\(stem) \(number)\(suffix)"
    }

    /// Counts a dangling link as present
    public static func occupied(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }
}
