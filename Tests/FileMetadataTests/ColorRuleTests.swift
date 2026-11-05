import Foundation
import FileMetadata
import HSpaceContracts
import HSpaceTestSupport
import Testing

private func item(_ name: String, directory: Bool = false, package: Bool = false, modified: Date? = nil) -> FileItem {
    FileItem(url: URL(fileURLWithPath: "/x/\(name)"), name: name, isDirectory: directory, isPackage: package,
             isSymlink: false, isHidden: false, size: nil, modified: modified, created: nil, contentTypeID: nil)
}

private let now = Date(timeIntervalSince1970: 1_000_000)

private func color(_ item: FileItem, _ rules: [ColorRule], metadata: ItemMetadata? = nil) -> FileColor? {
    ColorRules.color(for: item, metadata: metadata, rules: rules, now: now)
}

@Suite struct ColorRuleTests {
    @Test func nameContainsIgnoresCase() {
        let rule = ColorRule(color: .red, condition: .nameContains("Draft"))
        #expect(color(item("my-DRAFT.txt"), [rule]) == .red)
        #expect(color(item("final.txt"), [rule]) == nil)
    }

    @Test func extensionMatchesFilesOnly() {
        let rule = ColorRule(color: .blue, condition: .fileExtension(["jpg", "PNG"]))
        #expect(color(item("a.png"), [rule]) == .blue)
        #expect(color(item("a.JPG"), [rule]) == .blue)
        #expect(color(item("a.png", directory: true), [rule]) == nil)
        #expect(color(item("jpg"), [rule]) == nil)
    }

    @Test func tagRuleReadsTheItemsTags() {
        let rule = ColorRule(color: .green, condition: .hasTag("work"))
        let tagged = ItemMetadata(tags: [FinderTag(name: "Work")])
        #expect(color(item("a"), [rule], metadata: tagged) == .green)
        #expect(color(item("a"), [rule]) == nil)
    }

    @Test func packagesAreNotFolders() {
        let rule = ColorRule(color: .green, condition: .isFolder)
        #expect(color(item("a", directory: true), [rule]) == .green)
        #expect(color(item("a.app", directory: true, package: true), [rule]) == nil)
    }

    @Test func modifiedWithinCountsDays() {
        let rule = ColorRule(color: .orange, condition: .modifiedWithin(days: 2))
        #expect(color(item("a", modified: now.addingTimeInterval(-86_400)), [rule]) == .orange)
        #expect(color(item("a", modified: now.addingTimeInterval(-3 * 86_400)), [rule]) == nil)
        #expect(color(item("a"), [rule]) == nil)
    }

    @Test func firstEnabledMatchWins() {
        let rules = [
            ColorRule(enabled: false, color: .red, condition: .nameContains("a")),
            ColorRule(color: .blue, condition: .nameContains("a")),
            ColorRule(color: .green, condition: .nameContains("a")),
        ]
        #expect(color(item("a"), rules) == .blue)
    }

    @Test func aColourOnTheItemBeatsRules() {
        let rules = [ColorRule(color: .blue, condition: .nameContains("a"))]
        #expect(color(item("a"), rules, metadata: ItemMetadata(color: .pink)) == .pink)
    }

    @Test func emptyTextMatchesNothing() {
        #expect(color(item("a"), [ColorRule(color: .red, condition: .nameContains(""))]) == nil)
    }
}

@Suite struct FileColorTests {
    let engine = FileMetadata()

    @Test func setsClearsAndUndoes() async throws {
        let dir = try FaultFixture.tempDir("hspace-color")
        defer { FaultFixture.remove(dir) }
        let file = dir.appendingPathComponent("a")
        try FaultFixture.write(to: file)

        let set = try await engine.apply(.color(.teal), to: [file])
        #expect(try await engine.read([file])[file]?.color == .teal)

        _ = try await engine.restore(set.changed)
        #expect(try await engine.read([file])[file] == nil)

        _ = try await engine.apply(.color(.red), to: [file])
        _ = try await engine.apply(.color(nil), to: [file])
        #expect(try await engine.read([file])[file] == nil)
    }

    @Test func anUnknownValueReadsAsNoColour() async throws {
        let dir = try FaultFixture.tempDir("hspace-color")
        defer { FaultFixture.remove(dir) }
        let file = dir.appendingPathComponent("a")
        try FaultFixture.write(to: file)
        setRawAttribute("com.hoax017.hspace.fileColor", Data("chartreuse".utf8), of: file)
        #expect(try await engine.read([file])[file] == nil)
    }

    @Test func noPermissionFailsPerItem() async throws {
        let dir = try FaultFixture.tempDir("hspace-color")
        defer { FaultFixture.remove(dir) }
        let file = dir.appendingPathComponent("a")
        try FaultFixture.write(to: file)
        try await FaultFixture.withMode(0o444, on: file) {
            let result = try await engine.apply(.color(.red), to: [file])
            #expect(result.failures.count == 1)
        }
    }

    @Test func anEjectedVolumeFailsPerItem() async throws {
        let volume = try ScratchVolume()
        let file = volume.url.appendingPathComponent("a")
        try FaultFixture.write(to: file)
        try volume.eject()
        let result = try await engine.apply(.color(.red), to: [file])
        #expect(result.failures.first?.errorClass == .external)
    }
}

@Suite struct MetadataStoreTests {
    private let rule = ColorRule(color: .red, condition: .nameContains("x"))

    @Test func survivesARestart() async throws {
        let dir = try FaultFixture.tempDir("hspace-mstore")
        defer { FaultFixture.remove(dir) }
        try await MetadataStore(directory: dir).setColorRules([rule])
        #expect(await MetadataStore(directory: dir).colorRules() == [rule])
    }

    @Test func aDamagedFileIsKeptAsideAndReported() async throws {
        let dir = try FaultFixture.tempDir("hspace-mstore")
        defer { FaultFixture.remove(dir) }
        try FaultFixture.write(Data("{ damaged".utf8), to: dir.appendingPathComponent("file-metadata.json"))

        let store = MetadataStore(directory: dir)
        #expect(await store.colorRules().isEmpty)
        let problem = await store.takeProblem()
        #expect(problem?.errorClass == .external)
        #expect(await store.takeProblem() == nil)
        let kept = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("corrupt-") }
        #expect(kept.count == 1)
    }

    @Test func aFailedSaveChangesNothing() async throws {
        let dir = try FaultFixture.tempDir("hspace-mstore")
        defer { FaultFixture.remove(dir) }
        let store = MetadataStore(directory: dir)
        try await store.setColorRules([rule])
        try await FaultFixture.withReadOnly(dir) {
            await #expect(throws: MetadataError.self) { try await store.setColorRules([]) }
        }
        #expect(await store.colorRules() == [rule])
    }

    @Test func aFullDiskFailsTheSave() async throws {
        let volume = try ScratchVolume()
        let store = MetadataStore(directory: volume.url)
        try volume.fill(leaving: 0)
        let many = (0..<20_000).map { ColorRule(color: .red, condition: .nameContains("rule number \($0)")) }
        await #expect(throws: MetadataError.self) { try await store.setColorRules(many) }
        #expect(await store.colorRules().isEmpty)
    }
}
