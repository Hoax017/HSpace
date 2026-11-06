import Foundation
import HSpaceTestSupport
import SidebarColors
import Testing

@Suite struct SidebarColorSettingsTests {
    @Test func noColourByDefault() {
        #expect(SidebarColorSettings().color(for: "a", index: 0) == nil)
    }

    @Test func anItemsOwnColourBeatsThePalette() {
        let settings = SidebarColorSettings(palette: .mono, items: ["a": .red])
        #expect(settings.color(for: "a", index: 0) == .red)
        #expect(settings.color(for: "b", index: 0) == .gray)
    }

    @Test func thePaletteIsDealtInTurnAndWraps() {
        let settings = SidebarColorSettings(palette: .cool)
        let colors = SidebarPalette.cool.colors
        #expect(settings.color(for: "a", index: 0) == colors[0])
        #expect(settings.color(for: "a", index: 1) == colors[1])
        #expect(settings.color(for: "a", index: colors.count) == colors[0])
    }

    @Test func aNegativeIndexGivesNoColour() {
        #expect(SidebarColorSettings(palette: .cool).color(for: "a", index: -1) == nil)
    }

    @Test func onlyStandardIsEmpty() {
        for palette in SidebarPalette.allCases {
            #expect(palette.colors.isEmpty == (palette == .standard))
        }
    }

    @Test func keysDoNotCollide() {
        let id = UUID()
        #expect(SidebarItemKey.bookmark(id) != SidebarItemKey.place(path: id.uuidString))
    }
}

@Suite struct SidebarColorStoreTests {
    private let fileName = "sidebar-colors.json"

    @Test func choicesSurviveARestart() throws {
        let dir = try FaultFixture.tempDir("hspace-sidebarcolors")
        defer { FaultFixture.remove(dir) }
        let store = SidebarColorStore(directory: dir)
        try store.setColor(.green, for: "a")
        try store.setPalette(.warm)
        let reloaded = SidebarColorStore(directory: dir).settings()
        #expect(reloaded.items == ["a": .green])
        #expect(reloaded.palette == .warm)
    }

    @Test func nilRemovesTheColour() throws {
        let dir = try FaultFixture.tempDir("hspace-sidebarcolors")
        defer { FaultFixture.remove(dir) }
        let store = SidebarColorStore(directory: dir)
        try store.setColor(.green, for: "a")
        try store.setColor(nil, for: "a")
        #expect(store.settings().items.isEmpty)
    }

    @Test func aFailedWriteChangesNothing() async throws {
        let dir = try FaultFixture.tempDir("hspace-sidebarcolors")
        defer { FaultFixture.remove(dir) }
        let store = SidebarColorStore(directory: dir)
        try store.setColor(.green, for: "a")
        try await FaultFixture.withReadOnly(dir) {
            #expect(throws: SidebarColorError.self) { try store.setColor(.red, for: "a") }
            #expect(throws: SidebarColorError.self) { try store.setPalette(.mono) }
        }
        #expect(store.settings() == SidebarColorSettings(items: ["a": .green]))
    }

    @Test func aDamagedFileIsKeptAndReported() throws {
        let dir = try FaultFixture.tempDir("hspace-sidebarcolors")
        defer { FaultFixture.remove(dir) }
        try FaultFixture.write(Data("nope".utf8), to: dir.appendingPathComponent(fileName))
        let store = SidebarColorStore(directory: dir)
        #expect(store.settings() == SidebarColorSettings())
        #expect(store.takeProblem() != nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.contains { $0.contains("corrupt") })
        try store.setPalette(.cool)
        #expect(SidebarColorStore(directory: dir).settings().palette == .cool)
    }

    @Test func anUnknownColourCountsAsDamageNotAsNothing() throws {
        let dir = try FaultFixture.tempDir("hspace-sidebarcolors")
        defer { FaultFixture.remove(dir) }
        try FaultFixture.write(Data(#"{"palette":"standard","items":{"a":"plaid"}}"#.utf8), to: dir.appendingPathComponent(fileName))
        #expect(SidebarColorStore(directory: dir).takeProblem() != nil)
    }

    @Test func aDamagedFileThatCannotMoveIsNeverOverwritten() async throws {
        let dir = try FaultFixture.tempDir("hspace-sidebarcolors")
        defer { FaultFixture.remove(dir) }
        let file = dir.appendingPathComponent(fileName)
        try FaultFixture.write(Data("nope".utf8), to: file)
        try await FaultFixture.withReadOnly(dir) {
            let store = SidebarColorStore(directory: dir)
            #expect(throws: SidebarColorError.self) { try store.setColor(.red, for: "a") }
        }
        #expect(try Data(contentsOf: file) == Data("nope".utf8))
    }
}
