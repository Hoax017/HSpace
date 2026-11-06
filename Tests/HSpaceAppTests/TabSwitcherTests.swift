import AppKit
import SessionStore
import Testing
@testable import HSpaceApp

@MainActor
private final class FakeHost: TabSwitcherHost {
    var entries: [TabSwitcherEntry]
    var committed: [Int] = []
    let switcherWindow: NSWindow? = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled],
                                             backing: .buffered, defer: true)

    init(_ workspaces: [Int]) {
        entries = workspaces.map { TabSwitcherEntry(workspace: $0, title: "tab\($0)", path: "/tab\($0)") }
    }

    func switcherEntries() -> [TabSwitcherEntry] { entries }
    func switcherCommit(_ workspace: Int) { committed.append(workspace) }
}

@MainActor @Suite struct TabSwitcherTests {
    private func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                                      context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
    }

    private func flags(_ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                                      context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58))
    }

    private func held(_ host: FakeHost) -> TabSwitcherController {
        let switcher = TabSwitcherController(host: host)
        switcher.currentModifiers = { .option }
        return switcher
    }

    @Test func aPressAndReleaseSwapsTheLastTwoTabs() throws {
        let host = FakeHost([2, 0, 1])
        let switcher = held(host)
        switcher.start(backward: false, heldModifiers: .option)
        #expect(switcher.isActive)
        #expect(switcher.handle(try flags([])) == false)
        #expect(host.committed == [0])
        #expect(!switcher.isActive)
    }

    @Test func tabStepsWhileTheModifierStaysDown() throws {
        let host = FakeHost([2, 0, 1])
        let switcher = held(host)
        switcher.start(backward: false, heldModifiers: .option)
        #expect(switcher.handle(try key(48, modifiers: .option)))
        #expect(switcher.selectedEntry?.workspace == 1)
        #expect(switcher.handle(try key(48, modifiers: [.option, .shift])))
        #expect(switcher.selectedEntry?.workspace == 0)
        _ = switcher.handle(try flags(.option))   // an unrelated change: still held
        #expect(host.committed.isEmpty)
        _ = switcher.handle(try flags([]))
        #expect(host.committed == [0])
    }

    @Test func escapeLeavesTheTabAlone() throws {
        let host = FakeHost([2, 0])
        let switcher = held(host)
        switcher.start(backward: false, heldModifiers: .option)
        #expect(switcher.handle(try key(53)))
        #expect(!switcher.isActive)
        #expect(switcher.handle(try flags([])) == false)
        #expect(host.committed.isEmpty)
    }

    @Test func anotherKeyIsSwallowedSoNothingHappensBehindThePanel() throws {
        let host = FakeHost([2, 0])
        let switcher = held(host)
        switcher.start(backward: false, heldModifiers: .option)
        #expect(switcher.handle(try key(13, modifiers: .command)))
        #expect(switcher.isActive)
        switcher.cancel()
    }

    @Test func aShortcutAlreadyReleasedSwitchesAtOnce() {
        let host = FakeHost([2, 0])
        let switcher = TabSwitcherController(host: host)
        switcher.currentModifiers = { [] }
        switcher.start(backward: false, heldModifiers: .option)
        #expect(host.committed == [0])
        #expect(!switcher.isActive)
    }

    @Test func oneTabGivesNoSwitcher() {
        let host = FakeHost([0])
        let switcher = held(host)
        switcher.start(backward: false, heldModifiers: .option)
        #expect(!switcher.isActive)
        #expect(host.committed.isEmpty)
    }

    @Test func fromTheMenuItStaysUntilReturn() throws {
        let host = FakeHost([2, 0, 1])
        let switcher = held(host)
        switcher.start(backward: false, heldModifiers: [])
        #expect(switcher.isPanelVisible)
        #expect(switcher.shownRows.map(\.title) == ["tab2", "tab0", "tab1"])
        #expect(switcher.shownRows.map(\.subtitle) == ["/tab2", "/tab0", "/tab1"])
        _ = switcher.handle(try flags([]))
        #expect(switcher.isActive)
        #expect(switcher.handle(try key(125)))
        #expect(switcher.selectedEntry?.workspace == 1)
        #expect(switcher.handle(try key(36)))
        #expect(host.committed == [1])
        #expect(!switcher.isPanelVisible)
    }

    @Test func theHeldPanelAppearsAfterAMoment() async throws {
        let host = FakeHost([2, 0])
        let switcher = held(host)
        switcher.start(backward: false, heldModifiers: .option)
        defer { switcher.cancel() }
        await eventually("panel shows") { switcher.isPanelVisible }
        #expect(host.committed.isEmpty)
    }

    @Test func aStartOnARunningSwitcherIsIgnored() throws {
        let host = FakeHost([2, 0, 1])
        let switcher = held(host)
        switcher.start(backward: false, heldModifiers: .option)
        switcher.step(backward: false)
        switcher.start(backward: false, heldModifiers: .option)
        #expect(switcher.selectedEntry?.workspace == 1)
        switcher.cancel()
    }

    @Test func theMenuAndShortcutsAreRegistered() throws {
        NSApplication.shared.mainMenu = MainMenu.build()
        #expect(MainMenu.uiTestMenuItem(for: #selector(MainWindowController.showRecentTabs(_:))) != nil)
        #expect(KeyBindings.entry("recentTabs")?.defaultKey == "\t")
        #expect(KeyBindings.entry("recentTabsBack")?.defaultMods == [.option, .shift])
    }
}

@MainActor @Suite struct WorkspaceRecencyTests {
    private func workspace(_ path: String) -> SessionWindow {
        SessionWindow(layoutRaw: 1, panes: [SessionPane(tab: SessionTab(path: path))], activePaneIndex: 0)
    }

    @Test func recentOrderFollowsUseAndSurvivesAClose() {
        let manager = WorkspaceManager(initial: workspace("/a"))
        manager.append(workspace("/b"), limit: 0)
        manager.append(workspace("/c"), limit: 0)
        manager.switchTo(0)
        #expect(manager.recentOrder == [0, 2, 1])
        manager.close(at: 1)
        #expect(manager.recentOrder == [0, 1])
        #expect(manager.titles() == ["a", "c"])
    }

    @Test func closingTheActiveTabReturnsToTheOneUsedBefore() {
        let manager = WorkspaceManager(initial: workspace("/a"))
        manager.append(workspace("/b"), limit: 0)
        manager.append(workspace("/c"), limit: 0)
        manager.switchTo(0)
        manager.close(at: 0)
        #expect(manager.activeState.panes.first?.tab.path == "/c")
    }

    @Test func anEvictedTabLeavesTheOrder() {
        let manager = WorkspaceManager(initial: workspace("/a"))
        manager.append(workspace("/b"), limit: 2)
        manager.append(workspace("/c"), limit: 2)
        #expect(manager.titles() == ["b", "c"])
        #expect(manager.recentOrder == [1, 0])
    }

    @Test func aRestoredWindowListsEveryTab() {
        let manager = WorkspaceManager(states: [workspace("/a"), workspace("/b"), workspace("/c")], activeIndex: 1)
        #expect(manager.recentOrder == [1, 0, 2])
    }
}
