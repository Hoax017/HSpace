import AppKit
import BookmarkStore
import HSpaceTestSupport
import SidebarColors
import Testing
@testable import HSpaceApp

private final class MemoryColors: SidebarColorStoring, @unchecked Sendable {
    var contents = SidebarColorSettings()
    var failure: (any Error)?
    func settings() -> SidebarColorSettings { contents }
    func setColor(_ color: SidebarColor?, for key: String) throws {
        if let failure { throw failure }
        contents.items[key] = color
    }
    func setPalette(_ palette: SidebarPalette) throws {
        if let failure { throw failure }
        contents.palette = palette
    }
    func takeProblem() -> SidebarColorError? { nil }
}

private struct Refused: LocalizedError {
    var errorDescription: String? { "refused" }
}

@MainActor @Suite struct SidebarColorWiringTests {
    private func model(_ colors: MemoryColors) async throws -> (SidebarModel, URL) {
        let dir = try FaultFixture.tempDir("hspace-sidebarcolors")
        let store = BookmarkStore(directory: dir)
        let folder = dir.appendingPathComponent("Work")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try await store.add(folder)
        return (SidebarModel(bookmarkStore: store, colors: colors), dir)
    }

    private func bookmarks(of model: SidebarModel) async -> [SidebarLeafNode] {
        model.rebuild()
        await eventually("rebuilt") { model.groups.contains { $0.kind == .bookmarks } }
        return model.groups.first { $0.kind == .bookmarks }?.children ?? []
    }

    @Test func aBookmarkHasNoColourUntilGivenOne() async throws {
        let (model, dir) = try await model(MemoryColors())
        defer { FaultFixture.remove(dir) }
        let leaf = try #require(await bookmarks(of: model).first)
        #expect(leaf.tint == nil)
        #expect(leaf.chosenColor == nil)
    }

    @Test func aChosenColourTintsAnIconThatCanTakeIt() async throws {
        let colors = MemoryColors()
        let (model, dir) = try await model(colors)
        defer { FaultFixture.remove(dir) }
        let key = try #require(await bookmarks(of: model).first).colorKey
        colors.contents.items[key] = .red
        model.rebuild()
        await eventually("recoloured") { model.groups.first { $0.kind == .bookmarks }?.children.first?.chosenColor != nil }
        let leaf = try #require(await bookmarks(of: model).first)
        #expect(leaf.tint == .systemRed)
        #expect(leaf.chosenColor == .red)
        #expect(leaf.icon.isTemplate)
    }

    @Test func aPaletteColoursEveryLocationGroup() async throws {
        let colors = MemoryColors()
        colors.contents.palette = .mono
        let (model, dir) = try await model(colors)
        defer { FaultFixture.remove(dir) }
        _ = await bookmarks(of: model)
        for leaf in model.groups.flatMap(\.children) {
            #expect(leaf.tint == .systemGray, "\(leaf.title)")
            #expect(leaf.icon.isTemplate, "\(leaf.title)")
        }
    }

    @Test func thePaletteIsNotTheItemsOwnColour() async throws {
        let colors = MemoryColors()
        colors.contents.palette = .mono
        let (model, dir) = try await model(colors)
        defer { FaultFixture.remove(dir) }
        let leaf = try #require(await bookmarks(of: model).first)
        #expect(leaf.chosenColor == nil)
    }

    @Test func everyColourHasASystemColourAndAName() throws {
        let strings = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/en.lproj/Localizable.strings")
        let text = try String(contentsOf: strings, encoding: .utf8)
        #expect(Set(SidebarColor.allCases.map(\.nsColor)).count == SidebarColor.allCases.count)
        for color in SidebarColor.allCases { #expect(text.contains("\"sidebar.color.\(color.rawValue)\" = ")) }
        for palette in SidebarPalette.allCases { #expect(text.contains("\"sidebar.palette.\(palette.rawValue)\" = ")) }
    }

    @Test func theMenuTicksTheCurrentColour() throws {
        let item = SidebarColorMenu.colorItem(current: .teal, target: self as AnyObject, action: #selector(NSObject.description))
        let entries = try #require(item.submenu).items.filter { !$0.isSeparatorItem }
        #expect(entries.count == SidebarColor.allCases.count + 1)
        #expect(entries.filter { $0.state == .on }.map { $0.representedObject as? String } == ["teal"])
        #expect(entries.first?.representedObject as? String == "")
        #expect(entries.dropFirst().allSatisfy { $0.image != nil })
    }

    @Test func noColourTicksNone() throws {
        let item = SidebarColorMenu.colorItem(current: nil, target: self as AnyObject, action: #selector(NSObject.description))
        #expect(item.submenu?.items.first?.state == .on)
    }

    @Test func thePaletteMenuListsEveryPalette() throws {
        let item = SidebarColorMenu.paletteItem(current: .warm, target: self as AnyObject, action: #selector(NSObject.description))
        let entries = try #require(item.submenu).items
        #expect(entries.count == SidebarPalette.allCases.count)
        #expect(entries.filter { $0.state == .on }.map { $0.representedObject as? String } == ["warm"])
    }

    @Test func aSavedChoiceTellsTheWindows() async {
        var heard = 0
        let observer = NotificationCenter.default.addObserver(forName: .hspaceThemeChanged, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { heard += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        #expect(SidebarColorsHost.apply {} == nil)
        #expect(heard == 1)
    }

    @Test func aFailedChoiceIsReportedAndChangesNothingOnScreen() {
        var heard = 0
        let observer = NotificationCenter.default.addObserver(forName: .hspaceThemeChanged, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { heard += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        #expect(SidebarColorsHost.apply { throw Refused() } == "refused")
        #expect(heard == 0)
    }
}
