import Testing
import Foundation
import TrashLedger
import NSpaceContracts

/// Black-box acceptance: real temp directory + real persistence (no fakes or mocks)
@Suite struct TrashLedgerTests {
    static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nspace-tl-\(UUID().uuidString)")
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
}
