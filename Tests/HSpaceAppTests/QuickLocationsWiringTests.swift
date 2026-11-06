import AppKit
import Frecency
import HSpaceTestSupport
import QuickLocations
import Testing
@testable import HSpaceApp

@MainActor @Suite struct QuickPanelTests {
    private func content(_ names: [String], chosen: @escaping (QuickRow, NSEvent.ModifierFlags) -> Void = { _, _ in },
                         closed: @escaping () -> Void = {}) -> QuickPanelContent {
        QuickPanelContent(placeholder: "Find", rows: { query in
            names.filter { query.isEmpty || $0.contains(query) }.map { QuickRow(id: $0, title: $0, symbol: "folder") }
        }, choose: chosen, onClose: closed)
    }

    @Test func typingFilters() {
        let panel = QuickPanelController()
        panel.show(content(["alpha", "beta", "gamma"]), over: nil)
        defer { panel.close() }
        #expect(panel.rows.count == 3)
        #expect(panel.selectedRow?.id == "alpha")
        panel.setQuery("et")
        #expect(panel.rows.map(\.id) == ["beta"])
        #expect(panel.selectedRow?.id == "beta")
    }

    @Test func nothingFoundSaysSoAndReturnChoosesNothing() {
        var chosen: [String] = []
        let panel = QuickPanelController()
        panel.show(content(["alpha"], chosen: { row, _ in chosen.append(row.id) }), over: nil)
        defer { panel.close() }
        #expect(!panel.showsEmptyMessage)
        panel.setQuery("zzz")
        #expect(panel.showsEmptyMessage)
        panel.chooseSelected(modifiers: [])
        #expect(chosen.isEmpty)
        #expect(panel.isVisible)
    }

    @Test func arrowsStopAtBothEnds() {
        let panel = QuickPanelController()
        panel.show(content(["a", "b"]), over: nil)
        defer { panel.close() }
        panel.moveSelection(by: -1)
        #expect(panel.selectedRow?.id == "a")
        panel.moveSelection(by: 5)
        #expect(panel.selectedRow?.id == "b")
    }

    @Test func choosingClosesFirstAndPassesTheModifiers() {
        var chosen: [(String, NSEvent.ModifierFlags)] = []
        var visibleDuringChoice = true
        let panel = QuickPanelController()
        panel.show(content(["a", "b"], chosen: { row, modifiers in
            visibleDuringChoice = panel.isVisible
            chosen.append((row.id, modifiers))
        }), over: nil)
        panel.moveSelection(by: 1)
        panel.chooseSelected(modifiers: .command)
        #expect(chosen.first?.0 == "b")
        #expect(chosen.first?.1 == .command)
        #expect(!visibleDuringChoice)
        #expect(!panel.isVisible)
    }

    @Test func aRefreshKeepsTheHighlightOnItsRow() {
        var names = ["a", "b"]
        let panel = QuickPanelController()
        panel.show(QuickPanelContent(placeholder: "", rows: { _ in names.map { QuickRow(id: $0, title: $0, symbol: "folder") } },
                                     choose: { _, _ in }), over: nil)
        defer { panel.close() }
        panel.moveSelection(by: 1)
        names = ["new", "a", "b"]
        panel.refresh()
        #expect(panel.selectedRow?.id == "b")
    }

    @Test func aSecondShowClosesTheFirst() {
        var closed = 0
        let panel = QuickPanelController()
        panel.show(content(["a"], closed: { closed += 1 }), over: nil)
        panel.show(content(["b"]), over: nil)
        defer { panel.close() }
        #expect(closed == 1)
        #expect(panel.rows.map(\.id) == ["b"])
    }

    @Test func closingTwiceReportsOnce() {
        var closed = 0
        let panel = QuickPanelController()
        panel.show(content(["a"], closed: { closed += 1 }), over: nil)
        panel.close()
        panel.close()
        #expect(closed == 1)
    }
}

@MainActor @Suite struct QuickLocationsModelTests {
    private let home = URL(fileURLWithPath: "/Users/me")
    private func model() -> QuickLocationsModel {
        QuickLocationsModel(fixed: [QuickLocation(kind: .bookmark, title: "Work", path: "/Users/me/Work"),
                                    QuickLocation(kind: .volume, title: "Disk", path: "/Volumes/Disk")], home: home)
    }

    @Test func aTypedPathComesFirst() {
        let rows = model().rows("~/Work")
        #expect(rows.first?.id == "/Users/me/Work")
        #expect(rows.first?.trailing == L10n.t("quick.kind.typed"))
        #expect(rows.count == 1)
    }

    @Test func recentsAddWhatBookmarksLack() {
        let model = model()
        model.setRecents([QuickLocation(kind: .recent, title: "Work", path: "/Users/me/Work"),
                          QuickLocation(kind: .recent, title: "Old", path: "/old")])
        #expect(model.rows("").map(\.id) == ["/Users/me/Work", "/Volumes/Disk", "/old"])
        #expect(model.location(for: "/old", query: "")?.kind == .recent)
    }

    @Test func filteringUsesTheSearchRanking() {
        #expect(model().rows("dsk").map(\.title) == ["Disk"])   // an abbreviation, as focused search allows
    }

    @Test func everyKindHasAName() throws {
        // L10n has no bundle in a test run, so the strings file itself is the proof
        let strings = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/en.lproj/Localizable.strings")
        let text = try String(contentsOf: strings, encoding: .utf8)
        for kind in [QuickLocationKind.bookmark, .place, .volume, .recent, .typed] {
            #expect(text.contains("\"quick.kind.\(kind.rawValue)\" = "))
        }
    }

    @Test func recentFoldersComeFromUsageAndStillExist() async throws {
        let dir = try FaultFixture.tempDir("hspace-quickrecent")
        defer { FaultFixture.remove(dir) }
        let support = dir.appendingPathComponent("support")
        let often = dir.appendingPathComponent("often")
        let once = dir.appendingPathComponent("once")
        let gone = dir.appendingPathComponent("gone")
        let file = dir.appendingPathComponent("file.txt")
        for folder in [support, often, once] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false) }
        try FaultFixture.write(to: file)
        let store = FrecencyStore(directory: support)
        for url in [often, often, often, once, gone, file] { await store.record(url) }
        let folders = await QuickLocationsModel.recentFolders(from: store)
        #expect(folders.map(\.title) == ["often", "once"])
        #expect(folders.allSatisfy { $0.kind == .recent && $0.habit > 0 })
    }

    @Test func noUsageStoreMeansNoRecents() async {
        #expect(await QuickLocationsModel.recentFolders(from: nil).isEmpty)
    }

    @Test func theMenuAndShortcutsAreRegistered() {
        NSApplication.shared.mainMenu = MainMenu.build()
        #expect(MainMenu.uiTestMenuItem(for: #selector(MainWindowController.showQuickLocations(_:)))?.ownerTitle == L10n.t("menu.go"))
        #expect(MainMenu.uiTestMenuItem(for: #selector(MainWindowController.showBookmarkPanel(_:)))?.ownerTitle == L10n.t("menu.go"))
        #expect(KeyBindings.entry("quickLocations") != nil)
        #expect(KeyBindings.entry("goToBookmark") != nil)
    }
}
