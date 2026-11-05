import Foundation
import HSpaceContracts
import HSpaceKernel
import HSpaceTestSupport
import LocalOps
import Testing
import Transfer
@testable import HSpaceApp

/// H6: through the real kernel and nodes. The grid is weak in the coordinator and goes away at once: no window is involved.
@MainActor @Suite struct RestoreTests {
    private func coordinator() async -> FileOpsCoordinator {
        let kernel = OperationKernel()
        await kernel.register(TransferNode(), for: [.copy, .move, .duplicate])
        await kernel.register(LocalOpsNode(), for: [.rename, .newFolder, .newFile, .trash])
        return FileOpsCoordinator(kernel: kernel, grid: PaneGridController(initialDirectory: URL(fileURLWithPath: "/")))
    }

    private func restored(_ items: [TrashedItem], by coordinator: FileOpsCoordinator) async -> RestoreOutcome {
        await withCheckedContinuation { done in
            coordinator.restore(items) { done.resume(returning: $0) }
        }
    }

    @Test func aRestoredItemIsRenamedBackAndKnownByItsFinalPath() async throws {
        let dir = try FaultFixture.tempDir("hspace-restore")
        defer { FaultFixture.remove(dir) }
        let trashed = dir.appendingPathComponent("Trash/report 10.txt")
        let original = dir.appendingPathComponent("home/report.txt")
        try FaultFixture.write(to: trashed)
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        let outcome = await restored([TrashedItem(original: original, trashed: trashed)], by: await coordinator())
        #expect(outcome.restored == 1)
        #expect(outcome.landed.map(\.lastPathComponent) == ["report.txt"])
        #expect(FileManager.default.fileExists(atPath: original.path))
    }

    /// Redo trashes `landed`. After a failure the original path may hold an unrelated file, which redo must not touch.
    @Test func aFailedRestoreLeavesNothingForRedo() async throws {
        let dir = try FaultFixture.tempDir("hspace-restore")
        defer { FaultFixture.remove(dir) }
        let trashed = dir.appendingPathComponent("Trash/report.txt")
        let home = dir.appendingPathComponent("home")
        try FaultFixture.write(to: trashed)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let coordinator = await coordinator()
        chmod(home.path, 0o555)
        let outcome = await restored([TrashedItem(original: home.appendingPathComponent("report.txt"), trashed: trashed)],
                                     by: coordinator)
        chmod(home.path, 0o755)
        #expect(outcome.restored == 0)
        #expect(outcome.landed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: trashed.path))
    }
}
