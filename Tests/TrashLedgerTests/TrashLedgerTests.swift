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

    // MARK: Offline volumes (C5)

    @Test func entryOnAnEjectedVolumeSurvivesLoad() async throws {
        let dir = try FaultFixture.tempDir("hspace-tl-volume")
        defer { FaultFixture.remove(dir) }
        let volume = try ScratchVolume()
        let trashed = volume.url.appendingPathComponent(".Trashes/501/photo.jpg")
        let local = dir.appendingPathComponent("local.txt")
        try FaultFixture.write(to: trashed)
        try FaultFixture.write(to: local)
        await TrashLedger(directory: dir).record([
            (original: volume.url.appendingPathComponent("photo.jpg"), trashed: trashed),
            (original: dir.appendingPathComponent("o/local.txt"), trashed: local),
        ])

        try volume.eject()
        try FileManager.default.removeItem(at: local)
        let afterEject = TrashLedger(directory: dir)
        #expect(await afterEject.origin(of: trashed) != nil)
        #expect(await afterEject.origin(of: local) == nil)      // its volume is here, so the item is really gone
        // Loading wrote the file back: the record must still be there for the next launch
        #expect(await TrashLedger(directory: dir).origin(of: trashed) != nil)
    }

    @Test func entryOnAMountedVolumeIsPrunedWhenItsItemIsGone() async throws {
        let dir = try FaultFixture.tempDir("hspace-tl-volume")
        defer { FaultFixture.remove(dir) }
        let volume = try ScratchVolume()
        let trashed = volume.url.appendingPathComponent(".Trashes/501/photo.jpg")
        try FaultFixture.write(to: trashed)
        await TrashLedger(directory: dir).record([
            (original: volume.url.appendingPathComponent("photo.jpg"), trashed: trashed),
        ])
        try FileManager.default.removeItem(at: trashed)
        #expect(await TrashLedger(directory: dir).origin(of: trashed) == nil)
    }

    /// Ledgers written before C5 have no volume field.
    @Test func olderEntryUnderAMissingVolumeSurvivesLoad() async throws {
        let dir = try FaultFixture.tempDir("hspace-tl-volume")
        defer { FaultFixture.remove(dir) }
        let trashed = URL(fileURLWithPath: "/Volumes/HSpaceGone-\(UUID().uuidString)/.Trashes/501/a.txt")
        let entry = TrashLedgerEntry(trashedPath: trashed.path, originalPath: "/Volumes/x/a.txt", recordedAt: Date())
        try JSONEncoder().encode([entry]).write(to: dir.appendingPathComponent("trash-ledger.json"))
        #expect(await TrashLedger(directory: dir).origin(of: trashed) != nil)
    }

    // MARK: Nothing lands in the Trash without a record (C4)

    @Test func trashGuardCoversRootAndDescendantsOnly() throws {
        let dir = try FaultFixture.tempDir("hspace-tl-guard")
        defer { FaultFixture.remove(dir) }
        let trash = dir.appendingPathComponent(".Trash")
        let nested = trash.appendingPathComponent("folder/sub")
        let lookalike = dir.appendingPathComponent(".Trash-old")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lookalike, withIntermediateDirectories: true)

        #expect(TrashGuard.isInside(trash, anyOf: [trash]))
        #expect(TrashGuard.isInside(nested, anyOf: [dir.appendingPathComponent("other"), trash]))
        #expect(!TrashGuard.isInside(lookalike, anyOf: [trash]))
        #expect(!TrashGuard.isInside(dir, anyOf: [trash]))
    }

    @Test func trashGuardSeesThroughSymlinks() throws {
        let dir = try FaultFixture.tempDir("hspace-tl-guard")
        defer { FaultFixture.remove(dir) }
        let trash = dir.appendingPathComponent(".Trash")
        let inner = trash.appendingPathComponent("inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let alias = dir.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: trash)
        let safe = dir.appendingPathComponent("safe")
        try FileManager.default.createDirectory(at: safe, withIntermediateDirectories: true)
        let wayOut = inner.appendingPathComponent("wayOut")
        try FileManager.default.createSymbolicLink(at: wayOut, withDestinationURL: safe)

        #expect(TrashGuard.isInside(alias, anyOf: [trash]))
        #expect(TrashGuard.isInside(alias.appendingPathComponent("inner"), anyOf: [trash]))
        #expect(!TrashGuard.isInside(wayOut, anyOf: [trash]))        // a link out of the Trash lands outside it
    }

    // MARK: Empty Trash record lifetime (C3)

    @Test func itemsThatFailedToEraseKeepTheirRecord() async throws {
        let dir = try FaultFixture.tempDir("hspace-tl-erase")
        defer { FaultFixture.remove(dir) }
        let gone = dir.appendingPathComponent("gone.txt")
        let stuck = dir.appendingPathComponent("stuck.txt")
        try FaultFixture.write(to: gone)
        try FaultFixture.write(to: stuck)
        let led = TrashLedger(directory: dir)
        await led.record([(original: dir.appendingPathComponent("o/gone.txt"), trashed: gone),
                          (original: dir.appendingPathComponent("o/stuck.txt"), trashed: stuck)])
        let receipt = OperationReceipt(id: UUID(), filesDone: 1, bytesDone: 0, duration: 0, failures: [
            OperationFailure(url: stuck, errorClass: .external, message: "busy"),
        ])
        await led.forgetErased([gone, stuck], receipt: receipt)
        #expect(await led.origin(of: gone) == nil)
        #expect(await led.origin(of: stuck) != nil)
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

/// D1: a ledger that cannot be read is kept aside and reported, because rewriting it loses every Put Back record.
@Suite struct TrashLedgerDamagedFileTests {
    let garbage = Data("{not json".utf8)

    func corruptDirectory() throws -> (dir: URL, file: URL) {
        let dir = try FaultFixture.tempDir("hspace-tl")
        let file = dir.appendingPathComponent("trash-ledger.json")
        try garbage.write(to: file)
        return (dir, file)
    }

    func keptFiles(_ dir: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("trash-ledger.json.corrupt-") }
    }

    func item(in dir: URL) throws -> (original: URL, trashed: URL) {
        let trashed = dir.appendingPathComponent("in-trash.txt")
        try FaultFixture.write(to: trashed)
        return (dir.appendingPathComponent("orig/in-trash.txt"), trashed)
    }

    @Test func corruptFileIsKeptAsideAndReported() async throws {
        let (dir, file) = try corruptDirectory()
        defer { FaultFixture.remove(dir) }
        let ledger = TrashLedger(directory: dir)
        #expect(await ledger.count() == 0)
        let kept = try #require(try keptFiles(dir).first)
        #expect(try Data(contentsOf: kept) == garbage)
        let problem = try #require(await ledger.takeProblem())
        #expect(problem.localizedDescription.contains(kept.lastPathComponent))
        #expect(await ledger.takeProblem() == nil, "reported once")

        await ledger.record([try item(in: dir)])
        #expect(try Data(contentsOf: kept) == garbage)
        #expect(try Data(contentsOf: file) != garbage)
        #expect(await TrashLedger(directory: dir).count() == 1)
    }

    @Test func unreadableFileIsKeptAside() async throws {
        let (dir, file) = try corruptDirectory()
        defer { FaultFixture.remove(dir) }
        let ledger = TrashLedger(directory: dir)
        try await FaultFixture.withMode(0o000, on: file) {
            #expect(await ledger.count() == 0)
        }
        #expect(await ledger.takeProblem() != nil)
        await ledger.record([try item(in: dir)])
        let kept = try #require(try keptFiles(dir).first)
        chmod(kept.path, 0o644)
        #expect(try Data(contentsOf: kept) == garbage)
    }

    @Test func fileThatCannotBeMovedBlocksWritesUntilItCan() async throws {
        let (dir, file) = try corruptDirectory()
        defer { FaultFixture.remove(dir) }
        let pair = try item(in: dir)
        let ledger = TrashLedger(directory: dir)
        try await FaultFixture.withReadOnly(dir) {
            #expect(await ledger.count() == 0)
            #expect(await ledger.takeProblem() != nil)
            await ledger.record([pair])
            #expect(await ledger.takeProblem() != nil, "the record is not on disk, so say so")
        }
        #expect(try keptFiles(dir).isEmpty, "nothing moved yet")
        #expect(try Data(contentsOf: file) == garbage)
        // Writable again: the next write moves the original aside first, and the record held in memory lands
        await ledger.record([pair])
        let kept = try #require(try keptFiles(dir).first)
        #expect(try Data(contentsOf: kept) == garbage)
        let located = try #require(await ledger.takeProblem())
        #expect(located.localizedDescription.contains(kept.lastPathComponent))
        #expect(await TrashLedger(directory: dir).count() == 1)
    }

    @Test func failedWriteIsReported() async throws {
        let dir = try FaultFixture.tempDir("hspace-tl")
        defer { FaultFixture.remove(dir) }
        let pair = try item(in: dir)
        let ledger = TrashLedger(directory: dir)
        try await FaultFixture.withReadOnly(dir) {
            await ledger.record([pair])
            #expect(await ledger.takeProblem() != nil)
        }
        #expect(await ledger.origin(of: pair.trashed) != nil, "memory keeps the record for this run")
        await ledger.record([pair])
        #expect(await ledger.takeProblem() == nil)
        #expect(await TrashLedger(directory: dir).count() == 1)
    }

    @Test func missingFileIsNotAProblem() async throws {
        let dir = try FaultFixture.tempDir("hspace-tl")
        defer { FaultFixture.remove(dir) }
        let ledger = TrashLedger(directory: dir)
        #expect(await ledger.count() == 0)
        #expect(await ledger.takeProblem() == nil)
    }
}
