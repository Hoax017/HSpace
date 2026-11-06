import AppKit
import SessionStore
import TabDrag
import Testing
@testable import HSpaceApp

@MainActor @Suite struct WorkspaceMoveTests {
    private func workspace(_ path: String) -> SessionWindow {
        SessionWindow(layoutRaw: 1, panes: [SessionPane(tab: SessionTab(path: path))], activePaneIndex: 0)
    }

    private func three() -> WorkspaceManager {
        WorkspaceManager(states: [workspace("/a"), workspace("/b"), workspace("/c")], activeIndex: 0)
    }

    @Test func aMoveKeepsTheSameWorkspaceActive() {
        let manager = three()
        #expect(manager.move(from: 0, to: 2))
        #expect(manager.titles() == ["b", "c", "a"])
        #expect(manager.activeIndex == 2)
    }

    @Test func movingAnotherTabPastTheActiveOneShiftsIt() {
        let manager = three()
        manager.switchTo(1)
        manager.move(from: 2, to: 0)
        #expect(manager.titles() == ["c", "a", "b"])
        #expect(WorkspaceManager.title(of: manager.activeState) == "b")
    }

    @Test func aMoveToNowhereIsRefused() {
        let manager = three()
        #expect(!manager.move(from: 1, to: 1))
        #expect(!manager.move(from: 0, to: -1))
        #expect(!manager.move(from: 0, to: 3))
        #expect(manager.titles() == ["a", "b", "c"])
    }

    @Test func recentOrderStaysOnTheSameWorkspaces() {
        let manager = three()
        manager.switchTo(2)
        manager.move(from: 2, to: 0)
        #expect(manager.titles() == ["c", "a", "b"])
        #expect(manager.titles()[manager.recentOrder[0]] == "c")
        #expect(manager.titles()[manager.recentOrder[1]] == "a")
    }

    @Test func anArrivingWorkspaceBecomesActive() {
        let manager = three()
        manager.insert(workspace("/x"), at: 1)
        #expect(manager.titles() == ["a", "x", "b", "c"])
        #expect(manager.activeIndex == 1)
        #expect(manager.titles()[manager.recentOrder[1]] == "a")
    }

    @Test func anOutOfRangeArrivalLandsAtTheEnd() {
        let manager = three()
        manager.insert(workspace("/x"), at: 99)
        #expect(manager.titles().last == "x")
    }
}

@MainActor @Suite struct TabBarDragTests {
    private func bar(_ titles: [String], active: Int = 0, in window: NSWindow? = nil) -> TabBarView {
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 600, height: 40))
        window?.contentView?.addSubview(bar)
        bar.update(titles: titles, active: active)
        bar.layoutSubtreeIfNeeded()
        return bar
    }

    private func window() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
    }

    @Test func anUpdateKeepsTheTabThatIsBeingPressed() {
        let bar = bar(["a", "b"])
        let first = bar.testItem(0)
        bar.update(titles: ["a2", "b2"], active: 1)
        #expect(bar.testItem(0) === first)
        #expect(bar.testItemTitle(0) == "a2")
        #expect(!bar.testItemIsActive(0))
        #expect(bar.testItemIsActive(1))
    }

    @Test func tabsComeAndGoWithTheList() {
        let bar = bar(["a", "b", "c"])
        bar.update(titles: ["a"], active: 0)
        #expect(bar.testItemCount == 1)
        bar.update(titles: ["x", "y"], active: 0)
        #expect(bar.testItemCount == 2)
        #expect(bar.testItemTitle(1) == "y")
    }

    @Test func aTabAddedLaterReportsItsOwnIndex() throws {
        let bar = bar(["a"])
        var selected: [Int] = []
        bar.onSelect = { selected.append($0) }
        bar.update(titles: ["a", "b"], active: 0)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        bar.testItem(1).mouseDown(with: event)
        #expect(selected == [1])
    }

    @Test func aDropInItsOwnWindowMoves() {
        let window = window()
        let bar = bar(["a", "b", "c"], in: window)
        var moves: [[Int]] = []
        bar.onMove = { moves.append([$0, $1]) }
        #expect(bar.drop(TabDragPayload(windowNumber: window.windowNumber, index: 0), inGap: 3))
        #expect(moves == [[0, 2]])
    }

    @Test func aDropBackOnItsPlaceIsTakenSoNothingDetaches() {
        let window = window()
        let bar = bar(["a", "b"], in: window)
        var moves = 0
        bar.onMove = { _, _ in moves += 1 }
        #expect(bar.drop(TabDragPayload(windowNumber: window.windowNumber, index: 1), inGap: 1))
        #expect(moves == 0)
    }

    @Test func aDropFromAnotherWindowIsAdopted() async {
        let window = window()
        let bar = bar(["a"], in: window)
        var adopted: [(TabDragPayload, Int)] = []
        bar.onAdopt = { adopted.append(($0, $1)) }
        let payload = TabDragPayload(windowNumber: window.windowNumber + 1, index: 2)
        #expect(bar.drop(payload, inGap: 1))
        await eventually("adopted") { !adopted.isEmpty }
        #expect(adopted.first?.0 == payload)
        #expect(adopted.first?.1 == 1)
    }

    @Test func theMarkSitsInTheGapWithoutMovingAnything() throws {
        let bar = bar(["aaaa", "bbbb"])
        let before = bar.testItem(1).frame
        bar.testShowInsertionMark(gap: 1)
        let mark = try #require(bar.testInsertionMarkFrame)
        #expect(mark.width == 2)
        #expect(abs(mark.midX - bar.testItem(1).convert(bar.testItem(1).bounds, to: bar).minX) < 1)
        #expect(bar.testItem(1).frame == before)
    }

    @Test func theMenusAreRegistered() {
        NSApplication.shared.mainMenu = MainMenu.build()
        for action in [#selector(MainWindowController.moveTabLeft(_:)), #selector(MainWindowController.moveTabRight(_:)),
                       #selector(MainWindowController.moveTabToNewWindow(_:))] {
            #expect(MainMenu.uiTestMenuItem(for: action)?.ownerTitle == L10n.t("menu.file"))
        }
    }

    @Test func tabsAreVisibleToVoiceOver() {
        let bar = bar(["a", "b"], active: 1)
        #expect(bar.testItem(1).isAccessibilityElement())
        #expect(bar.testItem(1).accessibilityLabel() == "b")
        #expect(bar.testItem(1).accessibilityValue() as? Int == 1)
        #expect(bar.testItem(0).accessibilityValue() as? Int == 0)
    }
}
