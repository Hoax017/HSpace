import FolderSync
import Foundation
import HSpaceContracts
import HSpaceKernel
import HSpaceTestSupport
import LocalOps
import OperationHistory
import Testing
import Transfer
@testable import HSpaceApp

/// Through the real kernel and Transfer, so a sync is checked against the engine that really copies.
/// Trash goes to the real Trash, with files each test made in its own folder.
@MainActor @Suite struct FolderSyncWiringTests {
    private func setup() async throws -> (dir: URL, left: URL, right: URL, coordinator: FileOpsCoordinator, store: HistoryStore) {
        let dir = try FaultFixture.tempDir("hspace-syncwiring")
        let left = dir.appendingPathComponent("left"), right = dir.appendingPathComponent("right")
        for folder in [left, right] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let kernel = OperationKernel()
        await kernel.register(TransferNode(), for: [.copy, .move, .duplicate])
        await kernel.register(LocalOpsNode(), for: [.rename, .newFolder, .newFile, .trash])
        let coordinator = FileOpsCoordinator(kernel: kernel, grid: PaneGridController(initialDirectory: URL(fileURLWithPath: "/")))
        let store = HistoryStore(directory: dir.appendingPathComponent("support"))
        coordinator.history = store
        return (dir, left, right, coordinator, store)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FaultFixture.write(Data(text.utf8), to: url)
    }

    @Test func aMirrorMatchesAndASecondCompareFindsNothing() async throws {
        let (dir, left, right, coordinator, _) = try await setup()
        defer { FaultFixture.remove(dir) }
        try write("new", to: left.appendingPathComponent("folder/new.txt"))
        try write("longer", to: left.appendingPathComponent("changed.txt"))
        try write("old", to: right.appendingPathComponent("changed.txt"))
        try write("extra", to: right.appendingPathComponent("extra.txt"))
        let options = SyncOptions(deleteExtras: true)
        let plan = try SyncPlanner.plan(left: left, right: right, options: options)
        let report = await SyncExecutor.run(plan, mode: .apply(confirmedDeletes: true), driver: coordinator.syncDriver())
        #expect(report.isClean)
        #expect(try SyncPlanner.plan(left: left, right: right, options: options).hasWork == false)
    }

    @Test func oneSyncIsOneHistoryLineAndUndoesWhole() async throws {
        let (dir, left, right, coordinator, store) = try await setup()
        defer { FaultFixture.remove(dir) }
        try write("new", to: left.appendingPathComponent("new.txt"))
        try write("longer", to: left.appendingPathComponent("changed.txt"))
        let target = right.appendingPathComponent("changed.txt")
        try write("old", to: target)
        let plan = try SyncPlanner.plan(left: left, right: right, options: SyncOptions())
        _ = await coordinator.historyGroup("Sync") {
            await SyncExecutor.run(plan, mode: .apply(confirmedDeletes: false), driver: coordinator.syncDriver())
        }
        let groups = await store.groups()
        #expect(groups.count == 1)
        #expect(await coordinator.undoHistory(groups[0]) == .undone(leftInPlace: 0))
        #expect(!FileManager.default.fileExists(atPath: right.appendingPathComponent("new.txt").path))
        #expect(try String(contentsOf: target, encoding: .utf8) == "old")
    }

    @Test func aDryRunThroughTheRealDriverLeavesNoTrace() async throws {
        let (dir, left, right, coordinator, store) = try await setup()
        defer { FaultFixture.remove(dir) }
        try write("new", to: left.appendingPathComponent("new.txt"))
        try write("extra", to: right.appendingPathComponent("extra.txt"))
        let plan = try SyncPlanner.plan(left: left, right: right, options: SyncOptions(deleteExtras: true))
        let report = await SyncExecutor.run(plan, mode: .dryRun, driver: coordinator.syncDriver())
        #expect(report.copied == 1 && report.deleted == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: right.path) == ["extra.txt"])
        #expect(await store.groups().isEmpty)
    }

    @Test func aRealFailureStopsBeforeTheDeletes() async throws {
        let (dir, left, right, coordinator, _) = try await setup()
        defer { FaultFixture.remove(dir) }
        try write("new", to: left.appendingPathComponent("new.txt"))
        try write("extra", to: right.appendingPathComponent("extra.txt"))
        let plan = try SyncPlanner.plan(left: left, right: right, options: SyncOptions(deleteExtras: true))
        chmod(right.path, 0o555)
        defer { chmod(right.path, 0o755) }
        let report = await SyncExecutor.run(plan, mode: .apply(confirmedDeletes: true), driver: coordinator.syncDriver())
        #expect(report.stoppedEarly)
        #expect(report.deleted == 0)
        #expect(FileManager.default.fileExists(atPath: right.appendingPathComponent("extra.txt").path))
    }

    @Test func patternsSplitOnSeparators() {
        #expect(FolderSyncModel.patterns("*.jpg; *.png, a b\n;") == ["*.jpg", "*.png", "a b"])
        #expect(FolderSyncModel.patterns("  ").isEmpty)
    }
}
