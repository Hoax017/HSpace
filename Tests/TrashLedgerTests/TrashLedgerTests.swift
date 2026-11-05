import Testing
import Foundation
import TrashLedger
import HSpaceContracts
import HSpaceTestSupport

/// Black-box acceptance: real temp directory + real persistence (no fakes or mocks)
@Suite struct TrashLedgerTests {
    static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hspace-tl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func recordsAndReadsBackOrigin() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let trashed = dir.appendingPathComponent("in-trash.txt")
        try Data("x".utf8).write(to: trashed)              // must really exist (self-pruning drops entries that do not)
        let original = dir.appendingPathComponent("orig/in-trash.txt")

        let led = TrashLedger(directory: dir)
        await led.record([(original: original, trashed: trashed)])
        let got = await led.origin(of: trashed)
        #expect(got?.standardizedFileURL.path == original.standardizedFileURL.path)
        #expect(await led.count() == 1)
    }

    @Test func survivesRestartViaDisk() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let trashed = dir.appendingPathComponent("t.txt")
        try Data("x".utf8).write(to: trashed)
        let original = dir.appendingPathComponent("o/t.txt")

        await TrashLedger(directory: dir).record([(original: original, trashed: trashed)])
        // A fresh instance = simulated restart, can only read from disk
        let fresh = TrashLedger(directory: dir)
        #expect(await fresh.origin(of: trashed) != nil)
    }

    @Test func selfPrunesEntriesWhoseTrashedItemIsGone() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let alive = dir.appendingPathComponent("alive.txt")
        let vanished = dir.appendingPathComponent("vanished.txt")
        try Data("x".utf8).write(to: alive)
        try Data("x".utf8).write(to: vanished)
        await TrashLedger(directory: dir).record([
            (original: dir.appendingPathComponent("o/alive.txt"), trashed: alive),
            (original: dir.appendingPathComponent("o/vanished.txt"), trashed: vanished),
        ])
        // The Trash item is gone (emptied / deleted by another app) → the entry must be voided, no handing out stale facts
        try FileManager.default.removeItem(at: vanished)
        let fresh = TrashLedger(directory: dir)
        #expect(await fresh.origin(of: vanished) == nil)
        #expect(await fresh.origin(of: alive) != nil)
        #expect(await fresh.count() == 1)
    }

    @Test func forgetRemovesEntry() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = dir.appendingPathComponent("t.txt")
        try Data("x".utf8).write(to: t)
        let led = TrashLedger(directory: dir)
        await led.record([(original: dir.appendingPathComponent("o/t.txt"), trashed: t)])
        await led.forget([t])
        #expect(await led.origin(of: t) == nil)
        #expect(await led.count() == 0)
    }

    @Test func unknownItemHasNoOrigin() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let led = TrashLedger(directory: dir)
        // An item deleted by another app: no record → must honestly return nil, and the caller grays it out
        #expect(await led.origin(of: dir.appendingPathComponent("stranger.txt")) == nil)
        let many = await led.origins(of: [dir.appendingPathComponent("a"), dir.appendingPathComponent("b")])
        #expect(many.isEmpty)
    }

    // MARK: Put Back record lifetime (C2)

    @Test func failedPutBackKeepsTheRecordAcrossRestart() async throws {
        let f = try Self.restoreFixture()
        defer { FaultFixture.remove(f.root) }
        let led = TrashLedger(directory: f.root)
        await led.record([(original: f.item.original, trashed: f.item.trashed)])
        // The original folder is gone or read-only: the move throws and the kernel has no receipt
        let step = TrashRestorePolicy.step(after: nil, of: f.item, landedWasOccupied: false)
        await led.settle(step, for: f.item.trashed)
        #expect(await TrashLedger(directory: f.root).origin(of: f.item.trashed) != nil)
    }

    @Test func successfulPutBackDropsTheRecord() async throws {
        let f = try Self.restoreFixture()
        defer { FaultFixture.remove(f.root) }
        let led = TrashLedger(directory: f.root)
        await led.record([(original: f.item.original, trashed: f.item.trashed)])
        try FileManager.default.moveItem(at: f.item.trashed, to: TrashRestorePolicy.landedURL(of: f.item))
        let step = TrashRestorePolicy.step(after: Self.okReceipt, of: f.item, landedWasOccupied: false)
        await led.settle(step, for: f.item.trashed)
        #expect(await led.count() == 0)
    }

    // MARK: Restore decision (C1)

    /// A Trash holding "report 10.txt", whose original was "report.txt" in `home`.
    static func restoreFixture() throws -> (root: URL, home: URL, item: TrashedItem) {
        let root = try FaultFixture.tempDir("hspace-tl-restore")
        let home = root.appendingPathComponent("home")
        let trashed = root.appendingPathComponent("Trash/report 10.txt")
        try FaultFixture.write(to: trashed)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (root, home, TrashedItem(original: home.appendingPathComponent("report.txt"), trashed: trashed))
    }
    static let okReceipt = OperationReceipt(id: UUID(), filesDone: 1, bytesDone: 0, duration: 0)

    @Test func failedMoveNeverRenamesAnUnrelatedFile() throws {
        let f = try Self.restoreFixture()
        defer { FaultFixture.remove(f.root) }
        try FaultFixture.write(to: f.home.appendingPathComponent("report 10.txt"))  // a stranger with the Trash name
        #expect(TrashRestorePolicy.step(after: nil, of: f.item, landedWasOccupied: true) == .notRestored)
    }

    @Test func failedMoveWithFreePathIsNotRestored() throws {
        let f = try Self.restoreFixture()
        defer { FaultFixture.remove(f.root) }
        #expect(TrashRestorePolicy.step(after: nil, of: f.item, landedWasOccupied: false) == .notRestored)
    }

    @Test func skippedConflictIsNotRestored() throws {
        let f = try Self.restoreFixture()
        defer { FaultFixture.remove(f.root) }
        try FaultFixture.write(to: f.home.appendingPathComponent("report 10.txt"))
        // Skip finishes cleanly with an empty receipt, and the item stays in the Trash
        let skipped = OperationReceipt(id: UUID(), filesDone: 0, bytesDone: 0, duration: 0)
        #expect(TrashRestorePolicy.step(after: skipped, of: f.item, landedWasOccupied: true) == .notRestored)
    }

    @Test func keepBothLeavesTheStrangerAlone() throws {
        let f = try Self.restoreFixture()
        defer { FaultFixture.remove(f.root) }
        try FaultFixture.write(to: f.home.appendingPathComponent("report 10.txt"))
        try FileManager.default.moveItem(at: f.item.trashed, to: f.home.appendingPathComponent("report 10 2.txt"))
        #expect(TrashRestorePolicy.step(after: Self.okReceipt, of: f.item, landedWasOccupied: true) == .restored)
    }

    @Test func partialFailureIsNotRestored() throws {
        let f = try Self.restoreFixture()
        defer { FaultFixture.remove(f.root) }
        let partial = OperationReceipt(id: UUID(), filesDone: 0, bytesDone: 0, duration: 0, failures: [
            OperationFailure(url: f.item.trashed, errorClass: .external, message: "no"),
        ])
        #expect(TrashRestorePolicy.step(after: partial, of: f.item, landedWasOccupied: false) == .notRestored)
    }

    @Test func cleanMoveWithTrashNameIsRenamedBack() throws {
        let f = try Self.restoreFixture()
        defer { FaultFixture.remove(f.root) }
        let landed = TrashRestorePolicy.landedURL(of: f.item)
        try FileManager.default.moveItem(at: f.item.trashed, to: landed)
        #expect(TrashRestorePolicy.step(after: Self.okReceipt, of: f.item, landedWasOccupied: false)
                == .rename(landed: landed, to: "report.txt"))
    }

    @Test func emptyFolderMoveReportsNoFilesButIsStillRenamedBack() throws {
        let f = try Self.restoreFixture()
        defer { FaultFixture.remove(f.root) }
        let trashedDir = f.root.appendingPathComponent("Trash/empty 10")
        try FileManager.default.createDirectory(at: trashedDir, withIntermediateDirectories: true)
        let item = TrashedItem(original: f.home.appendingPathComponent("empty"), trashed: trashedDir)
        let landed = TrashRestorePolicy.landedURL(of: item)
        try FileManager.default.moveItem(at: trashedDir, to: landed)
        let none = OperationReceipt(id: UUID(), filesDone: 0, bytesDone: 0, duration: 0)
        #expect(TrashRestorePolicy.step(after: none, of: item, landedWasOccupied: false)
                == .rename(landed: landed, to: "empty"))
    }

    @Test func sameNameNeedsNoRename() throws {
        let f = try Self.restoreFixture()
        defer { FaultFixture.remove(f.root) }
        let trashed = f.root.appendingPathComponent("Trash/plain.txt")
        try FaultFixture.write(to: f.home.appendingPathComponent("plain.txt"))
        let item = TrashedItem(original: f.home.appendingPathComponent("plain.txt"), trashed: trashed)
        #expect(TrashRestorePolicy.step(after: Self.okReceipt, of: item, landedWasOccupied: false) == .restored)
    }

    @Test func danglingLinkCountsAsOccupied() throws {
        let f = try Self.restoreFixture()
        defer { FaultFixture.remove(f.root) }
        let link = try FaultFixture.danglingLink(at: f.home.appendingPathComponent("link"))
        #expect(TrashRestorePolicy.isOccupied(link))
        #expect(!TrashRestorePolicy.isOccupied(f.home.appendingPathComponent("nothing")))
    }
}
