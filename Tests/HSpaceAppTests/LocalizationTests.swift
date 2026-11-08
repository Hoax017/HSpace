import Foundation
import HSpaceTestSupport
import Testing
@testable import HSpaceApp

// Localization (L68). en is the reference: every other language in Resources must hold exactly its keys, with format
// specifiers that take the same arguments, or String(format:) reads the wrong argument and can crash. The tables are
// read from the repository, since the test bundle carries none.

private let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let resources = root.appendingPathComponent("Resources")

/// The languages shipped besides English
private func otherLanguages() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: resources.path)
        .filter { $0.hasSuffix(".lproj") && $0 != "en.lproj" }
        .map { String($0.dropLast(".lproj".count)) }
        .sorted()
}

private func table(_ url: URL) throws -> [String: String] {
    try #require(NSDictionary(contentsOf: url) as? [String: String], "\(url.lastPathComponent) does not parse")
}

private func plist(_ url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
}

/// Keys written more than once in a strings file: the parser keeps the last one silently
private func duplicateKeys(_ url: URL) throws -> [String] {
    let text = try String(contentsOf: url, encoding: .utf8)
    let key = try NSRegularExpression(pattern: #"^\s*"((?:[^"\\]|\\.)*)"\s*="#, options: .anchorsMatchLines)
    var seen = Set<String>(), twice = [String]()
    for match in key.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        let name = String(text[Range(match.range(at: 1), in: text)!])
        if !seen.insert(name).inserted { twice.append(name) }
    }
    return twice
}

/// The arguments a format string reads, by position: `%@ %d` and `%2$d %1$@` read the same two
enum FormatArguments {
    private static let specifier = try! NSRegularExpression(
        pattern: #"%(?:([1-9][0-9]*)\$)?[-+ 0#']*[0-9]*(?:\.[0-9]+)?(hh|h|ll|l|q|z|t|j|L)?([@dDiuUxXoOfFeEgGaAcCsSp%])"#)

    /// Position → conversion (length modifier included: %d and %ld differ in size), or why the string is unusable
    static func of(_ format: String) -> Result<[Int: String], FormatProblem> {
        var arguments: [Int: String] = [:]
        var next = 1, positional = false, sequential = false
        for match in specifier.matches(in: format, range: NSRange(format.startIndex..., in: format)) {
            let conversion = String(format[Range(match.range(at: 3), in: format)!])
            if conversion == "%" { continue }
            let length = Range(match.range(at: 2), in: format).map { String(format[$0]) } ?? ""
            let position: Int
            if let explicit = Range(match.range(at: 1), in: format) {
                positional = true
                position = Int(format[explicit])!
            } else {
                sequential = true
                position = next
                next += 1
            }
            if positional && sequential { return .failure(.mixed) }
            let type = length + conversion
            if let earlier = arguments[position], earlier != type { return .failure(.conflict(position)) }
            arguments[position] = type
        }
        if let highest = arguments.keys.max(), highest != arguments.count { return .failure(.gap) }
        return .success(arguments)
    }
}

enum FormatProblem: Error, Equatable {
    /// `%1$@` and `%d` in one string
    case mixed
    /// One position read as two types
    case conflict(Int)
    /// `%2$@` with no `%1$`
    case gap
}

@Suite struct FormatArgumentsTests {
    @Test func reorderedPositionsReadTheSameArguments() throws {
        #expect(try FormatArguments.of("%@ (%d%%)").get() == [1: "@", 2: "d"])
        #expect(try FormatArguments.of("%2$d sur %1$@").get() == [1: "@", 2: "d"])
        #expect(try FormatArguments.of("%ld éléments").get() == [1: "ld"])
        #expect(try FormatArguments.of("100 %% sans argument").get() == [:])
    }

    @Test func unusableFormatsAreCaught() {
        #expect(FormatArguments.of("%1$@ et %d") == .failure(.mixed))
        #expect(FormatArguments.of("%2$@") == .failure(.gap))
        #expect(FormatArguments.of("%1$@ %1$d") == .failure(.conflict(1)))
    }

    @Test func aDifferentLengthIsADifferentArgument() throws {
        #expect(FormatArguments.of("%d") != FormatArguments.of("%ld"))
    }
}

@Suite struct LocalizationTests {
    @Test func everyLanguageHasExactlyTheEnglishKeys() throws {
        let english = try table(resources.appendingPathComponent("en.lproj/Localizable.strings"))
        #expect(english.count > 900)
        let languages = try otherLanguages()
        #expect(languages.contains("fr"))
        for language in languages {
            let other = try table(resources.appendingPathComponent("\(language).lproj/Localizable.strings"))
            let missing = Set(english.keys).subtracting(other.keys).sorted()
            let extra = Set(other.keys).subtracting(english.keys).sorted()
            #expect(missing.isEmpty, "\(language) lacks \(missing)")
            #expect(extra.isEmpty, "\(language) has keys English does not: \(extra)")
        }
    }

    @Test func noStringsFileRepeatsAKey() throws {
        for language in try ["en"] + otherLanguages() {
            let url = resources.appendingPathComponent("\(language).lproj/Localizable.strings")
            let twice = try duplicateKeys(url)
            #expect(twice.isEmpty, "\(language): \(twice)")
        }
    }

    @Test func translationsTakeTheSameFormatArguments() throws {
        let english = try table(resources.appendingPathComponent("en.lproj/Localizable.strings"))
        for (key, value) in english {
            #expect(throws: Never.self, "en \(key)") { try FormatArguments.of(value).get() }
        }
        for language in try otherLanguages() {
            let other = try table(resources.appendingPathComponent("\(language).lproj/Localizable.strings"))
            for (key, value) in other {
                guard let reference = english[key] else { continue }
                let expected = FormatArguments.of(reference)
                let found = FormatArguments.of(value)
                #expect(found == expected, "\(language) \(key): \(value)")
            }
        }
    }

    /// French typography: a no-break space before : ; ! ? and inside « », the ellipsis character, the typographic apostrophe
    @Test func frenchFollowsFrenchTypography() throws {
        let french = try table(resources.appendingPathComponent("fr.lproj/Localizable.strings"))
        let infoPlist = try table(resources.appendingPathComponent("fr.lproj/InfoPlist.strings"))
        let services = try table(resources.appendingPathComponent("fr.lproj/ServicesMenu.strings"))
        let breakingSpace = try NSRegularExpression(pattern: #" [:;!?»]|« |\p{L}[:!?](?:\s|$)"#)
        for (key, value) in french.merging(infoPlist, uniquingKeysWith: { a, _ in a }).merging(services, uniquingKeysWith: { a, _ in a }) {
            let range = NSRange(value.startIndex..., in: value)
            #expect(breakingSpace.firstMatch(in: value, range: range) == nil, "\(key): \(value)")
            #expect(!value.contains("..."), "\(key) uses three dots, not …")
            #expect(!value.contains("'"), "\(key) uses ' rather than ’")
            #expect(!value.contains("“") && !value.contains("”"), "\(key) uses English quotes rather than « »")
        }
    }

    @Test func theAppBundleDeclaresItsLanguages() throws {
        let info = try plist(root.appendingPathComponent("Support/Info.plist"))
        #expect(info["CFBundleDevelopmentRegion"] as? String == "en")
        #expect(info["CFBundleLocalizations"] as? [String] == ["en"] + (try otherLanguages()))
    }

    /// InfoPlist.strings may only name keys Info.plist has (or a document type name), and must cover every usage description
    @Test func infoPlistTextsAreTranslated() throws {
        let info = try plist(root.appendingPathComponent("Support/Info.plist"))
        let typeNames = (info["CFBundleDocumentTypes"] as? [[String: Any]] ?? []).compactMap { $0["CFBundleTypeName"] as? String }
        let known = Set(info.keys).union(typeNames)
        let usage = Set(info.keys.filter { $0.hasSuffix("UsageDescription") })
        #expect(!usage.isEmpty)
        for language in try otherLanguages() {
            let strings = try table(resources.appendingPathComponent("\(language).lproj/InfoPlist.strings"))
            #expect(Set(strings.keys).subtracting(known).isEmpty, "\(language) names unknown keys")
            #expect(usage.subtracting(strings.keys).isEmpty, "\(language) lacks \(usage.subtracting(strings.keys).sorted())")
            #expect(Set(typeNames).subtracting(strings.keys).isEmpty, "\(language) lacks a document type name")
        }
    }

    /// ServicesMenu.strings is keyed by the English menu title of each NSServices entry
    @Test func servicesMenuTitlesAreTranslated() throws {
        let info = try plist(root.appendingPathComponent("Support/Info.plist"))
        let titles = Set((info["NSServices"] as? [[String: Any]] ?? []).compactMap { ($0["NSMenuItem"] as? [String: String])?["default"] })
        #expect(titles.count == 4)
        for language in try otherLanguages() {
            let strings = try table(resources.appendingPathComponent("\(language).lproj/ServicesMenu.strings"))
            #expect(Set(strings.keys) == titles, "\(language)")
            #expect(strings.values.allSatisfy { $0.contains("HSpace") }, "\(language): each title names the app")
        }
    }

    @Test func everyExtensionIsNamedInEveryLanguage() throws {
        let extensions = root.appendingPathComponent("Support/Extensions")
        let folders = try FileManager.default.contentsOfDirectory(atPath: extensions.path).filter { !$0.hasPrefix(".") }
        #expect(folders.count == 2)
        for folder in folders {
            let base = extensions.appendingPathComponent(folder)
            let info = try plist(base.appendingPathComponent("Info.plist"))
            #expect(info["CFBundleDevelopmentRegion"] as? String == "en", "\(folder)")
            #expect(info["CFBundleLocalizations"] as? [String] == ["en"] + (try otherLanguages()), "\(folder)")
            for language in try otherLanguages() {
                let strings = try table(base.appendingPathComponent("\(language).lproj/InfoPlist.strings"))
                let name = try #require(strings["CFBundleDisplayName"], "\(folder) \(language)")
                #expect(name != info["CFBundleDisplayName"] as? String, "\(folder) \(language) is not translated")
            }
        }
    }

    @Test func theBuildShipsEveryLanguage() throws {
        let script = try String(contentsOf: root.appendingPathComponent("scripts/build-app.sh"), encoding: .utf8)
        #expect(script.contains("for LPROJ in Resources/*.lproj"))
        #expect(!script.contains("cp -R Resources/en.lproj"))
    }
}

/// A key the preferred language lacks shows in English, not as its key
@Suite struct L10nFallbackTests {
    @Test func aMissingKeyFallsBackToEnglish() throws {
        let dir = try FaultFixture.tempDir("hspace-l10n")
        defer { FaultFixture.remove(dir) }
        let english = dir.appendingPathComponent("en.lproj"), french = dir.appendingPathComponent("fr.lproj")
        for (folder, text) in [(english, #""a" = "A"; "b" = "B";"#), (french, #""a" = "À";"#)] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: folder.appendingPathComponent("Localizable.strings"))
        }
        let fr = try #require(Bundle(path: french.path)), en = try #require(Bundle(path: english.path))
        #expect(L10n.lookup("a", in: fr, fallback: en) == "À")
        #expect(L10n.lookup("b", in: fr, fallback: en) == "B")
        #expect(L10n.lookup("c", in: fr, fallback: en) == "c")
        #expect(L10n.lookup("b", in: fr, fallback: nil) == "b")
    }
}
