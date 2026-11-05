import FileTemplates
import Foundation
import HSpaceTestSupport
import Testing

private let utc = TimeZone(identifier: "UTC") ?? .current
private let posix = Locale(identifier: "en_US_POSIX")
/// 2026-03-09 14:05:07 UTC
private let moment = Date(timeIntervalSince1970: 1_773_065_107)

private func expand(_ name: String) -> String {
    TemplateName.expand(name, date: moment, locale: posix, timeZone: utc)
}

@Suite struct TemplateNameTests {
    @Test func aPlainNameStays() {
        #expect(expand("Report.md") == "Report.md")
    }

    @Test func aDateTokenExpands() {
        #expect(expand("Report $date(yyyy-MM-dd).md") == "Report 2026-03-09.md")
    }

    @Test func severalTokensExpand() {
        #expect(expand("$date(yyyy)/$date(MM) notes") == "2026-03 notes")
    }

    @Test func anEmptyFormatMeansTheDay() {
        #expect(expand("$date()") == "2026-03-09")
    }

    @Test func aFormatCanNameTheMonth() {
        #expect(expand("$date(MMMM d)") == "March 9")
    }

    @Test func quotedTextInAFormatStays() {
        #expect(expand("$date(yyyy'Q'Q)") == "2026Q1")
    }

    @Test func separatorsInAFormatBecomeDashes() {
        #expect(expand("$date(yyyy/MM/dd HH:mm)") == "2026-03-09 14-05")
    }

    @Test func anIncompleteTokenStays() {
        #expect(expand("$date(yyyy") == "$date(yyyy")
        #expect(expand("$date") == "$date")
        #expect(expand("cost $5") == "cost $5")
    }

    @Test func aFormatOfOnlyDotsCannotLeaveTheFolder() {
        #expect(expand("$date('..')") == "")
    }

    @Test func aTemplateWhoseNameExpandsToNothingKeepsItsOwn() throws {
        let dir = try FaultFixture.tempDir("hspace-template")
        defer { FaultFixture.remove(dir) }
        let file = dir.appendingPathComponent("$date('.')")
        try FaultFixture.write(to: file)
        let template = try #require(try TemplateLibrary(folder: dir).templates().first)
        #expect(template.displayName() == "$date('.')")
    }
}

@Suite struct TemplateLibraryTests {
    @Test func aMissingFolderHasNoTemplates() throws {
        let dir = try FaultFixture.tempDir("hspace-template")
        defer { FaultFixture.remove(dir) }
        #expect(try TemplateLibrary(folder: dir.appendingPathComponent("none")).templates().isEmpty)
    }

    @Test func templatesAreSortedAndHiddenItemsLeftOut() throws {
        let dir = try FaultFixture.tempDir("hspace-template")
        defer { FaultFixture.remove(dir) }
        for name in ["b 10.txt", "b 2.txt", ".DS_Store"] { try FaultFixture.write(to: dir.appendingPathComponent(name)) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("a folder"), withIntermediateDirectories: true)
        let templates = try TemplateLibrary(folder: dir).templates()
        #expect(templates.map(\.url.lastPathComponent) == ["a folder", "b 2.txt", "b 10.txt"])
        #expect(templates[0].isFolder)
        #expect(!templates[1].isFolder)
    }

    @Test func anUnreadableFolderFails() async throws {
        let dir = try FaultFixture.tempDir("hspace-template")
        defer { FaultFixture.remove(dir) }
        try await FaultFixture.withUnreadable(dir) {
            #expect(throws: TemplateError.self) { try TemplateLibrary(folder: dir).templates() }
        }
    }

    @Test func aBlockedFolderReportsTheFailure() throws {
        let dir = try FaultFixture.tempDir("hspace-template")
        defer { FaultFixture.remove(dir) }
        let blocker = dir.appendingPathComponent("file")
        try FaultFixture.write(to: blocker)
        #expect(throws: TemplateError.self) { try TemplateLibrary(folder: blocker.appendingPathComponent("sub")).prepareFolder() }
    }

    @Test func prepareMakesTheFolderAndCanRepeat() throws {
        let dir = try FaultFixture.tempDir("hspace-template")
        defer { FaultFixture.remove(dir) }
        let library = TemplateLibrary(folder: dir.appendingPathComponent("a/b"))
        try library.prepareFolder()
        try library.prepareFolder()
        #expect(FileManager.default.fileExists(atPath: library.folder.path))
    }

    private func template(_ name: String, in dir: URL, folder: Bool = false) throws -> FileTemplate {
        let url = dir.appendingPathComponent(name)
        if folder {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try FaultFixture.write(to: url)
        }
        return try #require(try TemplateLibrary(folder: dir).templates().first { $0.url.lastPathComponent == name })
    }

    @Test func aFreeNameIsUsedAsIs() throws {
        let dir = try FaultFixture.tempDir("hspace-template")
        defer { FaultFixture.remove(dir) }
        let target = try FaultFixture.tempDir("hspace-template")
        defer { FaultFixture.remove(target) }
        #expect(TemplateLibrary.targetName(for: try template("Note.md", in: dir), in: target) == "Note.md")
    }

    @Test func aTakenNameCounts() throws {
        let dir = try FaultFixture.tempDir("hspace-template")
        defer { FaultFixture.remove(dir) }
        let target = try FaultFixture.tempDir("hspace-template")
        defer { FaultFixture.remove(target) }
        for name in ["Note.md", "Note 2.md"] { try FaultFixture.write(to: target.appendingPathComponent(name)) }
        #expect(TemplateLibrary.targetName(for: try template("Note.md", in: dir), in: target) == "Note 3.md")
    }

    @Test func aDanglingLinkTakesTheName() throws {
        let dir = try FaultFixture.tempDir("hspace-template")
        defer { FaultFixture.remove(dir) }
        let target = try FaultFixture.tempDir("hspace-template")
        defer { FaultFixture.remove(target) }
        _ = try FaultFixture.danglingLink(at: target.appendingPathComponent("Note.md"))
        #expect(TemplateLibrary.targetName(for: try template("Note.md", in: dir), in: target) == "Note 2.md")
    }

    @Test func aFolderNameIsAllStem() throws {
        let dir = try FaultFixture.tempDir("hspace-template")
        defer { FaultFixture.remove(dir) }
        let target = try FaultFixture.tempDir("hspace-template")
        defer { FaultFixture.remove(target) }
        try FileManager.default.createDirectory(at: target.appendingPathComponent("v1.2 notes"), withIntermediateDirectories: true)
        #expect(TemplateLibrary.targetName(for: try template("v1.2 notes", in: dir, folder: true), in: target) == "v1.2 notes 2")
    }
}
