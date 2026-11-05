import Foundation
import HSpaceContracts
import HSpaceTestSupport
import OperationHistory
import Testing

private func entry(group: UUID? = nil, steps: [HistoryStep] = [], outcome: HistoryOutcome = .completed) -> HistoryEntry {
    HistoryEntry(groupID: group, kind: "copy", names: ["a"], itemCount: 1, steps: steps, outcome: outcome)
}

private func group(_ steps: [HistoryStep]) -> HistoryGroup {
    let line = entry(steps: steps)
    return HistoryGroup(id: line.groupID, entries: [line], isUndone: false)
}

private func receipt(created: [URL] = [], trashed: [TrashedItem] = []) -> OperationReceipt {
    OperationReceipt(id: UUID(), filesDone: 1, bytesDone: 0, duration: 0, createdURLs: created, trashedItems: trashed)
}

@Suite struct HistoryBuilderTests {
    private let a = URL(fileURLWithPath: "/tmp/hspace-none/a.txt")
    private let target = URL(fileURLWithPath: "/tmp/hspace-none/target")

    @Test func aNewCopyIsCreatedAndAMergeIsNot() {
        let spec = OperationSpec(kind: .copy, sources: [a], destination: target)
        let landed = target.appendingPathComponent("a.txt")
        #expect(HistoryBuilder.steps(of: spec, receipt: receipt(created: [landed]), occupiedBefore: [], startedAt: Date())
            == [.created(path: landed.path)])
        #expect(HistoryBuilder.steps(of: spec, receipt: receipt(created: [landed]), occupiedBefore: [landed.path], startedAt: Date())
            == [.joined(path: landed.path)])
    }

    @Test func occupiedTargetsAreSampledForCopiesAndMoves() throws {
        let dir = try FaultFixture.tempDir("hspace-history")
        defer { FaultFixture.remove(dir) }
        let source = dir.appendingPathComponent("a.txt")
        try FaultFixture.write(to: source)
        let copy = OperationSpec(kind: .copy, sources: [source], destination: dir)
        #expect(HistoryBuilder.occupiedTargets(of: copy) == [source.path])
        #expect(HistoryBuilder.occupiedTargets(of: OperationSpec(kind: .trash, sources: [source])).isEmpty)
    }

    @Test func aDanglingLinkCountsAsOccupied() throws {
        let dir = try FaultFixture.tempDir("hspace-history")
        defer { FaultFixture.remove(dir) }
        let link = try FaultFixture.danglingLink(at: dir.appendingPathComponent("a.txt"))
        let spec = OperationSpec(kind: .copy, sources: [URL(fileURLWithPath: "/elsewhere/a.txt")], destination: dir)
        #expect(HistoryBuilder.occupiedTargets(of: spec) == [link.path])
    }

    @Test func aSkippedMoveSourceDoesNotShiftThePairs() throws {
        let dir = try FaultFixture.tempDir("hspace-history")
        defer { FaultFixture.remove(dir) }
        let skipped = dir.appendingPathComponent("skipped.txt")
        try FaultFixture.write(to: skipped)
        let gone = dir.appendingPathComponent("gone.txt")
        let landed = target.appendingPathComponent("gone 2.txt")
        let spec = OperationSpec(kind: .move, sources: [skipped, gone], destination: target)
        #expect(HistoryBuilder.steps(of: spec, receipt: receipt(created: [landed]), occupiedBefore: [], startedAt: Date())
            == [.moved(from: gone.path, to: landed.path)])
    }

    @Test func aMoveOntoSomethingIsNotReversible() {
        let landed = target.appendingPathComponent("a.txt")
        let spec = OperationSpec(kind: .move, sources: [a], destination: target)
        #expect(HistoryBuilder.steps(of: spec, receipt: receipt(created: [landed]), occupiedBefore: [landed.path], startedAt: Date())
            == [.joined(path: landed.path)])
    }

    @Test func extractionTellsNewFromExisting() throws {
        let dir = try FaultFixture.tempDir("hspace-history")
        defer { FaultFixture.remove(dir) }
        let item = dir.appendingPathComponent("out")
        try FaultFixture.write(to: item)
        let spec = OperationSpec(kind: .extract, sources: [a])
        let before = Date(timeIntervalSinceNow: -60), after = Date(timeIntervalSinceNow: 60)
        #expect(HistoryBuilder.steps(of: spec, receipt: receipt(created: [item]), occupiedBefore: [], startedAt: before)
            == [.created(path: item.path)])
        #expect(HistoryBuilder.steps(of: spec, receipt: receipt(created: [item]), occupiedBefore: [], startedAt: after)
            == [.joined(path: item.path)])
    }

    @Test func renameTrashAndDeleteRecordWhatTheyCan() {
        let renamed = URL(fileURLWithPath: "/tmp/hspace-none/b.txt")
        #expect(HistoryBuilder.steps(of: OperationSpec(kind: .rename, sources: [a], newName: "b.txt"),
                                     receipt: receipt(created: [renamed]), occupiedBefore: [], startedAt: Date())
            == [.renamed(from: a.path, to: renamed.path)])
        let item = TrashedItem(original: a, trashed: renamed)
        #expect(HistoryBuilder.steps(of: OperationSpec(kind: .trash, sources: [a]),
                                     receipt: receipt(trashed: [item]), occupiedBefore: [], startedAt: Date())
            == [.trashed(original: a.path, trashed: renamed.path)])
        #expect(HistoryBuilder.steps(of: OperationSpec(kind: .delete, sources: [a], destination: target),
                                     receipt: receipt(), occupiedBefore: [], startedAt: Date()).isEmpty)
    }
}

@Suite struct HistoryUndoPlanTests {
    private func fixture() throws -> (URL, URL, URL) {
        let dir = try FaultFixture.tempDir("hspace-history")
        let origin = dir.appendingPathComponent("origin")
        let target = dir.appendingPathComponent("target")
        for folder in [origin, target] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        return (dir, origin, target)
    }

    @Test func stepsUndoNewestFirst() throws {
        let (dir, origin, target) = try fixture()
        defer { FaultFixture.remove(dir) }
        let first = target.appendingPathComponent("first"), second = target.appendingPathComponent("second")
        try FaultFixture.write(to: first)
        try FaultFixture.write(to: second)
        let plan = HistoryUndoPlanner.plan(group([.created(path: first.path), .moved(from: origin.appendingPathComponent("second").path, to: second.path)]))
        #expect(plan.actions == [.moveBack(current: second, original: origin.appendingPathComponent("second")), .discard(first)])
        #expect(plan.blockers.isEmpty)
    }

    @Test func aMovedItemThatLeftBlocks() throws {
        let (dir, origin, target) = try fixture()
        defer { FaultFixture.remove(dir) }
        let gone = target.appendingPathComponent("gone").path
        let plan = HistoryUndoPlanner.plan(group([.moved(from: origin.appendingPathComponent("a").path, to: gone)]))
        #expect(plan.actions.isEmpty)
        #expect(plan.blockers == [.missing(gone)])
    }

    @Test func aTakenOriginBlocks() throws {
        let (dir, origin, target) = try fixture()
        defer { FaultFixture.remove(dir) }
        let from = origin.appendingPathComponent("a"), to = target.appendingPathComponent("a")
        try FaultFixture.write(to: from)
        try FaultFixture.write(to: to)
        #expect(HistoryUndoPlanner.plan(group([.moved(from: from.path, to: to.path)])).blockers == [.occupied(from.path)])
    }

    @Test func aMoveUnderANewNameNeedsThatNameFreeAtTheOrigin() throws {
        let (dir, origin, target) = try fixture()
        defer { FaultFixture.remove(dir) }
        let to = target.appendingPathComponent("a 2")
        try FaultFixture.write(to: to)
        let clash = origin.appendingPathComponent("a 2")
        try FaultFixture.write(to: clash)
        let plan = HistoryUndoPlanner.plan(group([.moved(from: origin.appendingPathComponent("a").path, to: to.path)]))
        #expect(plan.blockers == [.occupied(clash.path)])
    }

    @Test func aRenameChecksBothNames() throws {
        let (dir, origin, _) = try fixture()
        defer { FaultFixture.remove(dir) }
        let old = origin.appendingPathComponent("old"), new = origin.appendingPathComponent("new")
        try FaultFixture.write(to: new)
        #expect(HistoryUndoPlanner.plan(group([.renamed(from: old.path, to: new.path)])).actions
            == [.renameBack(current: new, originalName: "old")])
        try FaultFixture.write(to: old)
        #expect(HistoryUndoPlanner.plan(group([.renamed(from: old.path, to: new.path)])).blockers == [.occupied(old.path)])
    }

    @Test func aCaseOnlyRenameIsNotBlockedByItself() throws {
        let (dir, origin, _) = try fixture()
        defer { FaultFixture.remove(dir) }
        let new = origin.appendingPathComponent("Name")
        try FaultFixture.write(to: new)
        let plan = HistoryUndoPlanner.plan(group([.renamed(from: origin.appendingPathComponent("name").path, to: new.path)]))
        #expect(plan.blockers.isEmpty)
    }

    @Test func emptiedTrashBlocksRestore() throws {
        let (dir, origin, target) = try fixture()
        defer { FaultFixture.remove(dir) }
        let plan = HistoryUndoPlanner.plan(group([.trashed(original: origin.path, trashed: target.appendingPathComponent("gone").path)]))
        #expect(plan.blockers.count == 1)
    }

    @Test func joinedItemsStayAndGoneItemsNeedNothing() throws {
        let (dir, _, target) = try fixture()
        defer { FaultFixture.remove(dir) }
        let plan = HistoryUndoPlanner.plan(group([.joined(path: target.path), .created(path: target.appendingPathComponent("gone").path)]))
        #expect(plan.actions.isEmpty && plan.blockers.isEmpty)
        #expect(plan.leftInPlace == 1 && plan.alreadyGone == 1)
    }

    @Test func onlyJoinedStepsCannotBeUndone() {
        #expect(!group([.joined(path: "/x")]).canUndo)
        #expect(group([.joined(path: "/x"), .created(path: "/y")]).canUndo)
        #expect(!group([]).canUndo)
    }
}

@Suite struct HistoryStoreTests {
    @Test func entriesSurviveAndGroupNewestFirst() async throws {
        let dir = try FaultFixture.tempDir("hspace-history")
        defer { FaultFixture.remove(dir) }
        let shared = UUID()
        let store = HistoryStore(directory: dir)
        await store.record(entry(group: shared))
        await store.record(entry(group: shared))
        await store.record(entry())
        let reopened = await HistoryStore(directory: dir).groups()
        #expect(reopened.count == 2)
        #expect(reopened[1].id == shared && reopened[1].entries.count == 2)
    }

    @Test func undoneSurvives() async throws {
        let dir = try FaultFixture.tempDir("hspace-history")
        defer { FaultFixture.remove(dir) }
        let store = HistoryStore(directory: dir)
        let line = entry(steps: [.created(path: "/x")])
        await store.record(line)
        await store.markUndone(line.groupID)
        let group = await HistoryStore(directory: dir).group(line.groupID)
        #expect(group?.isUndone == true)
        #expect(group?.canUndo == false)
    }

    @Test func theLimitDropsWholeOldestGroups() async throws {
        let dir = try FaultFixture.tempDir("hspace-history")
        defer { FaultFixture.remove(dir) }
        let store = HistoryStore(directory: dir, limit: 3)
        let old = UUID()
        await store.record(entry(group: old))
        await store.record(entry(group: old))
        await store.record(entry())
        await store.record(entry())
        #expect(await store.groups().count == 2)
        #expect(await store.group(old) == nil)
    }

    @Test func aGroupLargerThanTheLimitStays() async throws {
        let dir = try FaultFixture.tempDir("hspace-history")
        defer { FaultFixture.remove(dir) }
        let store = HistoryStore(directory: dir, limit: 1)
        let big = UUID()
        for _ in 0..<3 { await store.record(entry(group: big)) }
        #expect(await store.group(big)?.entries.count == 3)
    }

    @Test func aDamagedFileIsKeptAsideAndReported() async throws {
        let dir = try FaultFixture.tempDir("hspace-history")
        defer { FaultFixture.remove(dir) }
        let file = dir.appendingPathComponent("operation-history.json")
        try FaultFixture.write(Data("not json".utf8), to: file)
        let store = HistoryStore(directory: dir)
        #expect(await store.groups().isEmpty)
        #expect(await store.takeProblem() != nil)
        let kept = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("corrupt") }
        #expect(kept.count == 1)
        await store.record(entry())
        #expect(await store.groups().count == 1)
    }

    @Test func aFailedSaveIsReportedAndKeepsMemory() async throws {
        let dir = try FaultFixture.tempDir("hspace-history")
        defer { FaultFixture.remove(dir) }
        let store = HistoryStore(directory: dir)
        try await FaultFixture.withReadOnly(dir) {
            await store.record(entry())
            #expect(await store.takeProblem() != nil)
        }
        #expect(await store.groups().count == 1)
    }

    @Test func clearForgets() async throws {
        let dir = try FaultFixture.tempDir("hspace-history")
        defer { FaultFixture.remove(dir) }
        let store = HistoryStore(directory: dir)
        await store.record(entry())
        await store.clear()
        #expect(await HistoryStore(directory: dir).groups().isEmpty)
    }
}
