import AppKit
import FileInspector
import HSpaceContracts
import HSpaceTestSupport
import Testing
@testable import HSpaceApp

@MainActor @Suite struct InspectorWiringTests {
    private func item(_ url: URL, folder: Bool = false, size: Int64? = nil) -> FileItem {
        FileItem(url: url, name: url.lastPathComponent, isDirectory: folder, isPackage: false, isSymlink: false,
                 isHidden: false, size: size, modified: nil, created: nil, contentTypeID: nil)
    }

    private func settle(_ section: InspectorSectionView, until done: () -> Bool) async {
        for _ in 0..<400 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func aFileShowsItsFacts() async throws {
        let dir = try FaultFixture.tempDir("hspace-inspectorui")
        defer { FaultFixture.remove(dir) }
        let file = dir.appendingPathComponent("note.txt")
        try FaultFixture.write(Data("hello".utf8), to: file)
        let section = InspectorSectionView(frame: .zero)
        section.show(selection: [item(file, size: 5)], directory: dir)
        await settle(section) { section.testRows.contains(file.path) }
        #expect(section.testHeader == "note.txt")
        #expect(section.testRows.contains(file.path))
    }

    @Test func nothingSelectedDescribesTheFolderAndItsSize() async throws {
        let dir = try FaultFixture.tempDir("hspace-inspectorui")
        defer { FaultFixture.remove(dir) }
        try FaultFixture.write(to: dir.appendingPathComponent("a"))
        let section = InspectorSectionView(frame: .zero)
        section.show(selection: [], directory: dir)
        await settle(section) { !section.testRows.isEmpty && !section.testRows.contains(L10n.t("inspector.calculating")) }
        #expect(section.testHeader == dir.lastPathComponent)
        #expect(section.testRows.contains(dir.path))
        #expect(!section.testRows.contains(L10n.t("inspector.calculating")))
    }

    @Test func aVanishedItemSaysSoInPlace() async throws {
        let dir = try FaultFixture.tempDir("hspace-inspectorui")
        defer { FaultFixture.remove(dir) }
        let section = InspectorSectionView(frame: .zero)
        section.show(selection: [item(dir.appendingPathComponent("gone.txt"), size: 1)], directory: dir)
        await settle(section) { !section.testRows.isEmpty }
        #expect(section.testRows.first?.contains("gone.txt") == true)
    }

    @Test func severalAddUpTheirFoldersToo() async throws {
        let dir = try FaultFixture.tempDir("hspace-inspectorui")
        defer { FaultFixture.remove(dir) }
        let sub = dir.appendingPathComponent("sub")
        try FaultFixture.write(Data(repeating: 1, count: 8192), to: sub.appendingPathComponent("big"))
        let section = InspectorSectionView(frame: .zero)
        section.show(selection: [item(sub, folder: true), item(dir.appendingPathComponent("a"), size: 2)], directory: dir)
        #expect(section.testRows.contains(L10n.t("inspector.calculating")))
        await settle(section) { !section.testRows.contains(L10n.t("inspector.calculating")) }
        #expect(!section.testRows.contains(L10n.t("inspector.calculating")))
    }

    @Test func aFolderItCannotSizeDoesNotClaimAFullTotal() {
        let tally = SelectionTally([item(URL(fileURLWithPath: "/x"), folder: true)]).adding(folderBytes: 0, complete: false)
        let size = InspectorRows.rows(for: tally, stillCounting: false).last?.value
        #expect(size == L10n.f("inspector.atLeast", Formatters.size.string(fromByteCount: 0)))
    }

    @Test func unknownFactsLeaveNoEmptyLine() async throws {
        let dir = try FaultFixture.tempDir("hspace-inspectorui")
        defer { FaultFixture.remove(dir) }
        let facts = try await FileInspector().inspect(dir)
        let rows = InspectorRows.rows(for: facts)
        #expect(rows.allSatisfy { !$0.value.isEmpty })
        #expect(!rows.contains { $0.label == L10n.t("info.size") })
        #expect(InspectorRows.rows(for: facts, folderBytes: .unreadable).contains { $0.value == L10n.t("inspector.unreadable") })
    }
}
