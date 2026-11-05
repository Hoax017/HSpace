import Foundation
import FileMetadata
import HSpaceContracts
import HSpaceKernel
import HSpaceTestSupport
import Testing
@testable import HSpaceApp

private let red = FinderTag(name: "Red", color: .red)
private let blue = FinderTag(name: "Blue", color: .blue)
private let work = FinderTag(name: "Work")

/// Waits for something the app does asynchronously, failing the test instead of hanging.
@MainActor
func eventually(_ what: Comment, _ condition: () throws -> Bool) async rethrows {
    // Generous, because a busy CI runner can stall the whole test process for seconds
    let deadline = ContinuousClock.now + .seconds(30)
    while ContinuousClock.now < deadline {
        if try condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    Issue.record(what)
}

@Suite struct TagPickerStateTests {
    @Test func marksFollowTheSelection() {
        let state = TagPickerState(selection: [[red, work], [red]], known: [red, blue])
        #expect(state.rows.map(\.tag) == [red, blue, work])
        #expect(state.rows.map(\.mark) == [.on, .off, .mixed])
    }

    @Test func noChangeMeansNoEdit() {
        let state = TagPickerState(selection: [[red], []], known: [red])
        #expect(state.edit == nil)
    }

    @Test func aMixedRowLeftAloneStaysOutOfTheEdit() throws {
        var state = TagPickerState(selection: [[red, work], [work]], known: [red, blue, work])
        state.toggle("Blue")
        guard case .tags(let add, let remove)? = state.edit else {
            Issue.record("no edit")
            return
        }
        #expect(add == [blue])
        #expect(remove.isEmpty)
    }

    @Test func clickingMixedAppliesToAll() {
        var state = TagPickerState(selection: [[red], []], known: [red])
        state.toggle("red")
        #expect(state.rows[0].mark == .on)
        guard case .tags(let add, _)? = state.edit else {
            Issue.record("no edit")
            return
        }
        #expect(add == [red])
    }

    @Test func turningOffRemoves() {
        var state = TagPickerState(selection: [[red]], known: [red])
        state.toggle("Red")
        guard case .tags(_, let remove)? = state.edit else {
            Issue.record("no edit")
            return
        }
        #expect(remove == ["Red"])
    }

    @Test func addingAKnownNameJustTurnsItOn() {
        var state = TagPickerState(selection: [[]], known: [red])
        state.add(FinderTag(name: "RED", color: .blue))
        #expect(state.rows.count == 1)
        #expect(state.rows[0].mark == .on)
        state.add(work)
        #expect(state.newTags == [red, work])
    }
}

@MainActor @Suite struct TagDotsTests {
    @Test func showsTheLastThreeColours() {
        let dots = TagDotsView()
        let tags = [red, blue, work, FinderTag(name: "Green", color: .green)]
        dots.show(tags)
        #expect(dots.shownColors == [.blue, .none, .green])
        #expect(dots.toolTip == "Red, Blue, Work, Green")
        #expect(dots.accessibilityLabel() != nil)
    }

    @Test func noTagsTakesNoRoom() {
        let dots = TagDotsView()
        dots.show([red])
        dots.show([])
        #expect(dots.arrangedSubviews.isEmpty)
        #expect(dots.toolTip == nil)
    }
}

@MainActor @Suite struct TagListTests {
    private func folder() throws -> (dir: URL, a: URL, b: URL, c: URL) {
        let dir = try FaultFixture.tempDir("hspace-taglist")
        let urls = try ["a", "b", "c"].map { name in
            let url = dir.appendingPathComponent(name)
            try FaultFixture.write(to: url)
            return url
        }
        return (dir, urls[0], urls[1], urls[2])
    }

    private func names(_ model: DirectoryViewModel) -> [String] { model.items.map(\.name) }

    private func loaded(_ dir: URL) async -> DirectoryViewModel {
        let model = DirectoryViewModel(directory: dir)
        model.reload()
        await eventually("snapshot") { !model.items.isEmpty }
        return model
    }

    @Test func tagsArriveWithoutARowReload() async throws {
        let (dir, a, _, _) = try folder()
        defer { FaultFixture.remove(dir) }
        try Engines.metadata.setTags([red], on: a)
        let model = DirectoryViewModel(directory: dir)
        defer { model.stopWatching() }
        var changes = 0
        model.addOnMetadataChange { changes += 1 }
        model.reload()
        await eventually("tags") { model.metadata.values.map(\.tags) == [[red]] }
        #expect(changes == 1)
    }

    @Test func filterShowsOnlyMatchingItemsAndEndsOnNavigation() async throws {
        let (dir, a, _, c) = try folder()
        defer { FaultFixture.remove(dir) }
        try Engines.metadata.setTags([red], on: a)
        try Engines.metadata.setTags([FinderTag(name: "Blue", color: .blue)], on: c)
        let model = await loaded(dir)
        defer { model.stopWatching() }

        model.setTagFilter(["red"])
        await eventually("filtered") { names(model) == ["a"] }

        model.setTagFilter(["red", "blue"])
        await eventually("two tags") { names(model) == ["a", "c"] }

        model.setTagFilter([])
        await eventually("all") { names(model) == ["a", "b", "c"] }

        model.setTagFilter(["red"])
        await eventually("filtered again") { names(model) == ["a"] }
        model.navigate(to: dir)
        #expect(model.tagFilter.isEmpty)
        await eventually("filter ended") { names(model) == ["a", "b", "c"] }
    }

    @Test func tagSortOrdersAndCanBeTurnedOff() async throws {
        let (dir, a, b, c) = try folder()
        defer { FaultFixture.remove(dir) }
        try Engines.metadata.setTags([red], on: a)
        try Engines.metadata.setTags([blue], on: c)
        _ = b
        let model = await loaded(dir)
        defer { model.stopWatching() }

        model.setTagSort(ascending: true)
        await eventually("ascending") { names(model) == ["c", "a", "b"] }
        model.setTagSort(ascending: false)
        await eventually("descending") { names(model) == ["a", "c", "b"] }
        #expect(!FileGrouping.active(model))
        model.setTagSort(ascending: nil)
        await eventually("off") { names(model) == ["a", "b", "c"] }
    }

    @Test func columnParentsKeepTheirRows() async throws {
        let (dir, a, _, _) = try folder()
        defer { FaultFixture.remove(dir) }
        try Engines.metadata.setTags([red], on: a)
        let model = await loaded(dir)
        defer { model.stopWatching() }
        model.setTagFilter(["Red"])
        await eventually("filtered") { names(model) == ["a"] }
        let all = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).map {
            FileItem(url: $0, name: $0.lastPathComponent, isDirectory: false, isPackage: false, isSymlink: false,
                     isHidden: false, size: nil, modified: nil, created: nil, contentTypeID: nil)
        }
        #expect(model.arranged(all, metadata: model.metadata, applyFilter: false).count == 3)
    }
}

/// Through the coordinator: what a menu click really runs, including ⌘Z.
@MainActor @Suite struct TagUndoTests {
    private func coordinator() -> FileOpsCoordinator {
        FileOpsCoordinator(kernel: OperationKernel(), grid: PaneGridController(initialDirectory: URL(fileURLWithPath: "/")))
    }

    @Test func applyUndoRedo() async throws {
        let dir = try FaultFixture.tempDir("hspace-tagundo")
        defer { FaultFixture.remove(dir) }
        let file = dir.appendingPathComponent("a")
        try FaultFixture.write(to: file)
        try Engines.metadata.setTags([blue], on: file)
        let coordinator = coordinator()
        let undo = coordinator.undoManager
        undo.groupsByEvent = false

        undo.beginUndoGrouping()
        coordinator.applyMetadata(.tags(add: [red], remove: []), to: [file], actionName: "Tags")
        try await eventually("applied") { try Engines.metadata.tags(of: file) == [blue, red] }
        await eventually("undo registered") { undo.groupingLevel == 1 && undoRegistered(undo) }
        undo.endUndoGrouping()

        #expect(undo.canUndo)
        undo.undo()
        try await eventually("undone") { try Engines.metadata.tags(of: file) == [blue] }
        #expect(undo.canRedo)
        // Straight away on purpose: the redo has to wait for what the restore replaced
        undo.redo()
        try await eventually("redone") { try Engines.metadata.tags(of: file) == [blue, red] }
    }

    @Test func aFailedItemLeavesNothingToUndo() async throws {
        let dir = try FaultFixture.tempDir("hspace-tagundo")
        defer { FaultFixture.remove(dir) }
        let coordinator = coordinator()
        let undo = coordinator.undoManager
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        coordinator.applyMetadata(.tags(add: [red], remove: []), to: [dir.appendingPathComponent("gone")], actionName: "Tags")
        try await Task.sleep(for: .milliseconds(100))
        undo.endUndoGrouping()
        #expect(undo.undoActionName.isEmpty)
    }

    private func undoRegistered(_ undo: UndoManager) -> Bool {
        !undo.undoActionName.isEmpty
    }
}
