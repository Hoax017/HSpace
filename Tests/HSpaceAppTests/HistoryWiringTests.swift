import Foundation
import HSpaceContracts
import HSpaceKernel
import HSpaceTestSupport
import LocalOps
import OperationHistory
import Testing
import Transfer
@testable import HSpaceApp

private struct Answer: ConflictArbiter {
    let decision: ConflictDecision

    func arbitrate(operation id: UUID, conflicts: [FileConflict]) async -> [URL: ConflictDecision]? {
        Dictionary(uniqueKeysWithValues: conflicts.map { ($0.source, decision) })
    }
}

/// Through the real kernel, Transfer and LocalOps. Nothing here reaches the real Trash except what each test made in its own folder.
@MainActor @Suite struct HistoryWiringTests {
    private func coordinator(_ dir: URL, decision: ConflictDecision = .skip) async -> (FileOpsCoordinator, HistoryStore) {
        let kernel = OperationKernel()
        await kernel.register(TransferNode(), for: [.copy, .move, .duplicate])
        await kernel.register(LocalOpsNode(), for: [.rename, .newFolder, .newFile, .trash])
        await kernel.setArbiter(Answer(decision: decision))
        let coordinator = FileOpsCoordinator(kernel: kernel, grid: PaneGridController(initialDirectory: URL(fileURLWithPath: "/")))
        let store = HistoryStore(directory: dir.appendingPathComponent("support"))
        coordinator.history = store
        return (coordinator, store)
    }

    private func fixture() throws -> (dir: URL, file: URL, target: URL) {
        let dir = try FaultFixture.tempDir("hspace-historywiring")
        let file = dir.appendingPathComponent("file.txt")
        try FaultFixture.write(to: file)
        let target = dir.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return (dir, file, target)
    }

    private func transfer(_ coordinator: FileOpsCoordinator, _ urls: [URL], into target: URL, move: Bool) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            coordinator.transfer(urls: urls, into: target, move: move) { _ in done.resume() }
        }
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @Test func aMoveIsRecordedAndUndone() async throws {
        let (dir, file, target) = try fixture()
        defer { FaultFixture.remove(dir) }
        let (coordinator, store) = await coordinator(dir)
        await transfer(coordinator, [file], into: target, move: true)
        let groups = await store.groups()
        #expect(groups.count == 1)
        #expect(!exists(file))
        #expect(await coordinator.undoHistory(groups[0]) == .undone(leftInPlace: 0))
        #expect(exists(file))
        #expect(!exists(target.appendingPathComponent("file.txt")))
        #expect(await store.groups()[0].isUndone)
    }

    @Test func undoLeavesNoLineOfItsOwn() async throws {
        let (dir, file, target) = try fixture()
        defer { FaultFixture.remove(dir) }
        let (coordinator, store) = await coordinator(dir)
        await transfer(coordinator, [file], into: target, move: true)
        _ = await coordinator.undoHistory(await store.groups()[0])
        #expect(await store.groups().count == 1)
    }

    @Test func aMoveKeptUnderAnotherNameComesBackUnderItsOwn() async throws {
        let (dir, file, target) = try fixture()
        defer { FaultFixture.remove(dir) }
        try FaultFixture.write(to: target.appendingPathComponent("file.txt"))
        let (coordinator, store) = await coordinator(dir, decision: .keepBoth)
        await transfer(coordinator, [file], into: target, move: true)
        let groups = await store.groups()
        #expect(groups[0].steps == [.moved(from: file.path, to: target.appendingPathComponent("file 2.txt").path)])
        #expect(await coordinator.undoHistory(groups[0]) == .undone(leftInPlace: 0))
        #expect(exists(file))
        #expect(exists(target.appendingPathComponent("file.txt")))
    }

    @Test func aBlockedUndoTouchesNothing() async throws {
        let (dir, file, target) = try fixture()
        defer { FaultFixture.remove(dir) }
        let (coordinator, store) = await coordinator(dir)
        await transfer(coordinator, [file], into: target, move: true)
        try FaultFixture.write(Data("new".utf8), to: file)
        let group = await store.groups()[0]
        #expect(await coordinator.undoHistory(group) == .refused([.occupied(file.path)]))
        #expect(exists(target.appendingPathComponent("file.txt")))
        #expect(await store.groups()[0].isUndone == false)
    }

    @Test func aReplacingCopyHasNothingToUndo() async throws {
        let (dir, file, target) = try fixture()
        defer { FaultFixture.remove(dir) }
        try FaultFixture.write(Data("old".utf8), to: target.appendingPathComponent("file.txt"))
        let (coordinator, store) = await coordinator(dir, decision: .replace)
        await transfer(coordinator, [file], into: target, move: false)
        #expect(await store.groups()[0].steps == [.joined(path: target.appendingPathComponent("file.txt").path)])
        #expect(await store.groups()[0].canUndo == false)
    }

    @Test func allSkippedLeavesNoLine() async throws {
        let (dir, file, target) = try fixture()
        defer { FaultFixture.remove(dir) }
        try FaultFixture.write(to: target.appendingPathComponent("file.txt"))
        let (coordinator, store) = await coordinator(dir, decision: .skip)
        await transfer(coordinator, [file], into: target, move: false)
        #expect(await store.groups().isEmpty)
    }

    @Test func aFailedMoveIsRecordedWithoutSteps() async throws {
        let (dir, file, target) = try fixture()
        defer { FaultFixture.remove(dir) }
        let (coordinator, store) = await coordinator(dir)
        try FileManager.default.removeItem(at: file)
        await transfer(coordinator, [file], into: target, move: true)
        let group = try #require(await store.groups().first)
        #expect(group.failure != nil)
        #expect(!group.canUndo)
    }

    @Test func aGroupUndoesAsOneLine() async throws {
        let (dir, file, target) = try fixture()
        defer { FaultFixture.remove(dir) }
        let second = dir.appendingPathComponent("second.txt")
        try FaultFixture.write(to: second)
        let (coordinator, store) = await coordinator(dir)
        await coordinator.historyGroup("Both") {
            await transfer(coordinator, [file], into: target, move: true)
            await transfer(coordinator, [second], into: target, move: true)
        }
        let groups = await store.groups()
        #expect(groups.count == 1)
        #expect(groups[0].title == "Both")
        #expect(await coordinator.undoHistory(groups[0]) == .undone(leftInPlace: 0))
        #expect(exists(file) && exists(second))
    }

    @Test func anInlineRenameIsRecorded() async throws {
        let (dir, file, _) = try fixture()
        defer { FaultFixture.remove(dir) }
        let (coordinator, store) = await coordinator(dir)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            coordinator.rename(file, to: "other.txt") { _ in done.resume() }
        }
        #expect(await coordinator.undoHistory(await store.groups()[0]) == .undone(leftInPlace: 0))
        #expect(exists(file))
    }

    @Test func noStoreRecordsNothing() async throws {
        let (dir, file, target) = try fixture()
        defer { FaultFixture.remove(dir) }
        let (coordinator, store) = await coordinator(dir)
        coordinator.history = nil
        await transfer(coordinator, [file], into: target, move: true)
        #expect(await store.groups().isEmpty)
    }
}
