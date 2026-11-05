import AppKit
import HSpaceContracts
import HSpaceTestSupport
import Testing
@testable import HSpaceApp

@MainActor @Suite struct KeyboardSelectionWiringTests {
    private func folder(_ names: [String]) throws -> URL {
        let dir = try FaultFixture.tempDir("hspace-keyselect")
        for name in names { try FaultFixture.write(to: dir.appendingPathComponent(name)) }
        return dir
    }

    private func loaded(_ dir: URL) async throws -> DirectoryViewModel {
        let model = DirectoryViewModel(directory: dir)
        model.reload()
        for _ in 0..<300 where model.isLoading || model.items.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        return model
    }

    private func arrow(down: Bool, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                                      context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                                      keyCode: down ? 125 : 126))
    }

    @Test func spacePicksScatteredRowsInAList() async throws {
        let dir = try folder(["a", "b", "c", "d"])
        defer { FaultFixture.remove(dir) }
        let model = try await loaded(dir)
        defer { model.stopWatching() }
        let list = FileListViewController(model: model)
        _ = list.view
        for _ in 0..<300 where list.tableView.numberOfRows < 4 { try await Task.sleep(for: .milliseconds(10)) }
        let table = list.tableView

        table.toggleSelectionAtCursor()
        #expect(list.selectedItems.map(\.name) == ["a"])
        #expect(table.keyboardCursorRow == 1)

        #expect(table.moveKeyboardCursor(with: try arrow(down: true)))
        #expect(table.keyboardCursorRow == 2)
        table.toggleSelectionAtCursor()
        #expect(list.selectedItems.map(\.name) == ["a", "c"])
        #expect(table.keyboardCursorRow == 3)
    }

    @Test func spaceOnASelectedRowTakesItOut() async throws {
        let dir = try folder(["a", "b"])
        defer { FaultFixture.remove(dir) }
        let model = try await loaded(dir)
        defer { model.stopWatching() }
        let list = FileListViewController(model: model)
        _ = list.view
        for _ in 0..<300 where list.tableView.numberOfRows < 2 { try await Task.sleep(for: .milliseconds(10)) }
        list.tableView.toggleSelectionAtCursor()
        #expect(list.tableView.moveKeyboardCursor(with: try arrow(down: false)))
        list.tableView.toggleSelectionAtCursor()
        #expect(list.selectedItems.isEmpty)
    }

    @Test func anotherSelectionChangeEndsIt() async throws {
        let dir = try folder(["a", "b"])
        defer { FaultFixture.remove(dir) }
        let model = try await loaded(dir)
        defer { model.stopWatching() }
        let list = FileListViewController(model: model)
        _ = list.view
        for _ in 0..<300 where list.tableView.numberOfRows < 2 { try await Task.sleep(for: .milliseconds(10)) }
        list.tableView.toggleSelectionAtCursor()
        list.tableView.selectRowIndexes([1], byExtendingSelection: false)
        #expect(list.tableView.keyboardCursorRow == nil)
    }

    @Test func arrowsPassThroughWithoutACursor() async throws {
        let table = FocusReportingTableView()
        #expect(!table.moveKeyboardCursor(with: try arrow(down: true)))
        table.keyboardCursorRow = 0
        #expect(!table.moveKeyboardCursor(with: try arrow(down: true, modifiers: .shift)))
    }

    @Test func anEmptyFolderIsNoProblem() {
        FocusReportingTableView().toggleSelectionAtCursor()
    }

    @Test func spacePicksItemsInTheIconView() async throws {
        let dir = try folder(["a", "b", "c"])
        defer { FaultFixture.remove(dir) }
        let model = try await loaded(dir)
        defer { model.stopWatching() }
        var changes = 0
        let grid = FileIconGridViewController(model: model)
        grid.onSelectionChange = { changes += 1 }
        _ = grid.view

        grid.toggleSelectionAtCursor()
        grid.moveKeyboardCursor(by: 1)
        grid.toggleSelectionAtCursor()
        #expect(grid.selectedItems.map(\.name) == ["a", "c"])
        #expect(changes == 2)

        // At the last item the cursor stays, so Space takes it out again
        grid.toggleSelectionAtCursor()
        #expect(grid.selectedItems.map(\.name) == ["a"])
    }

    @Test func aCursorThatFellOffAShorterListHidesTheOutline() {
        let table = FocusReportingTableView()
        table.keyboardCursorRow = 5
        #expect(table.testCursorHidden)
    }
}
