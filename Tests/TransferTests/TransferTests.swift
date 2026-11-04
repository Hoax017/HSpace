import Testing
import Foundation
import Transfer
import NSpaceContracts

/// Black-box acceptance: only through the Contract public surface; real physical I/O on /tmp fixture trees (no fakes or mocks)
@Suite struct TransferTests {
    static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nspace-tr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func makeContext(onConflict: @escaping @Sendable ([FileConflict]) async -> [URL: ConflictDecision]? = { _ in [:] })
        -> NodeContext {
        NodeContext(operationID: UUID(), report: { _ in }, resolveConflicts: onConflict)
    }

    // MARK: keepBothName pure logic (Oracle: no file system needed)

    @Test func keepBothNamingSkipsExisting() {
        let dir = URL(fileURLWithPath: "/tmp/x")
        let existing = Set(["file 2.txt", "file 3.txt"])
        let name = keepBothName(for: URL(fileURLWithPath: "/src/file.txt"), in: dir,
                                existsCheck: { existing.contains($0.lastPathComponent) })
        #expect(name == "file 4.txt")
        let noExt = keepBothName(for: URL(fileURLWithPath: "/src/Makefile"), in: dir,
                                 existsCheck: { _ in false })
        #expect(noExt == "Makefile 2")
    }

    // MARK: Copy: byte-identical (real terminal-state Witness)

    @Test func copyTreeByteIdentical() async throws {
        let src = try Self.tempDir(), dst = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        try FileManager.default.createDirectory(at: src.appendingPathComponent("nested"),
                                                withIntermediateDirectories: true)
        try payload.write(to: src.appendingPathComponent("big.bin"))
        try Data("inner".utf8).write(to: src.appendingPathComponent("nested/inner.txt"))

        let spec = OperationSpec(kind: .copy, sources: [src.appendingPathComponent("big.bin"),
                                                        src.appendingPathComponent("nested")],
                                 destination: dst)
        let receipt = try await TransferNode().execute(spec, context: Self.makeContext())

        let copied = try Data(contentsOf: dst.appendingPathComponent("big.bin"))
        #expect(copied == payload)  // physical evidence: byte-for-byte identical
        let inner = try Data(contentsOf: dst.appendingPathComponent("nested/inner.txt"))
        #expect(inner == Data("inner".utf8))
        #expect(receipt.filesDone == 2)
        #expect(receipt.bytesDone >= Int64(payload.count))
    }

    // MARK: The four conflict options

    @Test func conflictKeepBothRenames() async throws {
        let src = try Self.tempDir(), dst = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        try Data("new".utf8).write(to: src.appendingPathComponent("f.txt"))
        try Data("old".utf8).write(to: dst.appendingPathComponent("f.txt"))

        let ctx = Self.makeContext { conflicts in
            Dictionary(uniqueKeysWithValues: conflicts.map { ($0.source, ConflictDecision.keepBoth) })
        }
        _ = try await TransferNode().execute(
            OperationSpec(kind: .copy, sources: [src.appendingPathComponent("f.txt")], destination: dst),
            context: ctx)
        #expect(try Data(contentsOf: dst.appendingPathComponent("f.txt")) == Data("old".utf8))
        #expect(try Data(contentsOf: dst.appendingPathComponent("f 2.txt")) == Data("new".utf8))
    }

    @Test func conflictReplaceOverwrites() async throws {
        let src = try Self.tempDir(), dst = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        try Data("new".utf8).write(to: src.appendingPathComponent("f.txt"))
        try Data("old".utf8).write(to: dst.appendingPathComponent("f.txt"))
        let ctx = Self.makeContext { c in
            Dictionary(uniqueKeysWithValues: c.map { ($0.source, ConflictDecision.replace) })
        }
        _ = try await TransferNode().execute(
            OperationSpec(kind: .copy, sources: [src.appendingPathComponent("f.txt")], destination: dst),
            context: ctx)
        #expect(try Data(contentsOf: dst.appendingPathComponent("f.txt")) == Data("new".utf8))
    }

    @Test func conflictSkipLeavesTarget() async throws {
        let src = try Self.tempDir(), dst = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        try Data("new".utf8).write(to: src.appendingPathComponent("f.txt"))
        try Data("old".utf8).write(to: dst.appendingPathComponent("f.txt"))
        let ctx = Self.makeContext { c in
            Dictionary(uniqueKeysWithValues: c.map { ($0.source, ConflictDecision.skip) })
        }
        let receipt = try await TransferNode().execute(
            OperationSpec(kind: .copy, sources: [src.appendingPathComponent("f.txt")], destination: dst),
            context: ctx)
        #expect(try Data(contentsOf: dst.appendingPathComponent("f.txt")) == Data("old".utf8))
        #expect(receipt.filesDone == 0)
    }

    @Test func conflictMergeUnionsFolders() async throws {
        let src = try Self.tempDir(), dst = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        try FileManager.default.createDirectory(at: src.appendingPathComponent("d"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dst.appendingPathComponent("d"), withIntermediateDirectories: true)
        try Data("fromSrc".utf8).write(to: src.appendingPathComponent("d/s.txt"))
        try Data("same-src".utf8).write(to: src.appendingPathComponent("d/both.txt"))
        try Data("fromDst".utf8).write(to: dst.appendingPathComponent("d/t.txt"))
        try Data("same-dst".utf8).write(to: dst.appendingPathComponent("d/both.txt"))
        let ctx = Self.makeContext { c in
            Dictionary(uniqueKeysWithValues: c.map { ($0.source, ConflictDecision.mergeFolders) })
        }
        _ = try await TransferNode().execute(
            OperationSpec(kind: .copy, sources: [src.appendingPathComponent("d")], destination: dst),
            context: ctx)
        // Union + same-named source overwrites (contract promise)
        #expect(try Data(contentsOf: dst.appendingPathComponent("d/s.txt")) == Data("fromSrc".utf8))
        #expect(try Data(contentsOf: dst.appendingPathComponent("d/t.txt")) == Data("fromDst".utf8))
        #expect(try Data(contentsOf: dst.appendingPathComponent("d/both.txt")) == Data("same-src".utf8))
    }

    // MARK: Conflict "Rename" and the self-source safety rule (M27-A/B)

    @Test func conflictRenameLandsToChosenName() async throws {
        let src = try Self.tempDir(), dst = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        try Data("new".utf8).write(to: src.appendingPathComponent("f.txt"))
        try Data("old".utf8).write(to: dst.appendingPathComponent("f.txt"))
        let ctx = Self.makeContext { c in
            Dictionary(uniqueKeysWithValues: c.map { ($0.source, ConflictDecision.rename("custom.txt")) })
        }
        _ = try await TransferNode().execute(
            OperationSpec(kind: .copy, sources: [src.appendingPathComponent("f.txt")], destination: dst),
            context: ctx)
        #expect(try Data(contentsOf: dst.appendingPathComponent("f.txt")) == Data("old".utf8))   // original target untouched
        #expect(try Data(contentsOf: dst.appendingPathComponent("custom.txt")) == Data("new".utf8))
    }

    @Test func conflictRenameCollisionDisambiguatesNeverOverwrites() async throws {
        let src = try Self.tempDir(), dst = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        try Data("new".utf8).write(to: src.appendingPathComponent("f.txt"))
        try Data("old".utf8).write(to: dst.appendingPathComponent("f.txt"))
        try Data("taken".utf8).write(to: dst.appendingPathComponent("custom.txt"))   // the user's new name collides with an existing item
        let ctx = Self.makeContext { c in
            Dictionary(uniqueKeysWithValues: c.map { ($0.source, ConflictDecision.rename("custom.txt")) })
        }
        _ = try await TransferNode().execute(
            OperationSpec(kind: .copy, sources: [src.appendingPathComponent("f.txt")], destination: dst),
            context: ctx)
        // A clash does not overwrite: the existing custom.txt stays intact, the new copy lands at "custom 2.txt"
        #expect(try Data(contentsOf: dst.appendingPathComponent("custom.txt")) == Data("taken".utf8))
        #expect(try Data(contentsOf: dst.appendingPathComponent("custom 2.txt")) == Data("new".utf8))
    }

    @Test func selfCopyReplaceNeverDeletesSource() async throws {
        // M27-B core safety rule: when copying within one directory destination==source, and even a "Replace" decision must never delete the source
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("f.txt")
        try Data("keepme".utf8).write(to: f)
        let ctx = Self.makeContext { c in
            Dictionary(uniqueKeysWithValues: c.map { ($0.source, ConflictDecision.replace) })
        }
        _ = try await TransferNode().execute(
            OperationSpec(kind: .copy, sources: [f], destination: dir), context: ctx)
        // Source still present and intact; replace safely neutralized into a renamed copy
        #expect(try Data(contentsOf: f) == Data("keepme".utf8))
        #expect(try Data(contentsOf: dir.appendingPathComponent("f 2.txt")) == Data("keepme".utf8))
    }

    @Test func selfCopyMergeNeverSelfRecurses() async throws {
        // Copying a directory within its own parent + "Merge" decision: a destination==source directory must not recurse into itself, safely degrades to a renamed copy
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("d")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: sub.appendingPathComponent("a.txt"))
        let ctx = Self.makeContext { c in
            Dictionary(uniqueKeysWithValues: c.map { ($0.source, ConflictDecision.mergeFolders) })
        }
        _ = try await TransferNode().execute(
            OperationSpec(kind: .copy, sources: [sub], destination: dir), context: ctx)
        #expect(FileManager.default.fileExists(atPath: sub.appendingPathComponent("a.txt").path))
        #expect(try Data(contentsOf: dir.appendingPathComponent("d 2/a.txt")) == Data("x".utf8))
    }

    @Test func selfCopyThroughSymlinkAliasNeverDeletesSource() async throws {
        // Data safety hardening (review HIGH): when the source is reached through a symlink alias, lexical path comparison misses self-source → replace deletes the source.
        // The inode-level check must identify the alias as the same file, safely degrading replace to rename, never deleting the source.
        let base = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let f = real.appendingPathComponent("f.txt")
        try Data("keepme".utf8).write(to: f)
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        // Copy real/f.txt into the link directory (= alias of real) → destination=link/f.txt is physically the source
        let ctx = Self.makeContext { c in
            Dictionary(uniqueKeysWithValues: c.map { ($0.source, ConflictDecision.replace) })
        }
        _ = try await TransferNode().execute(
            OperationSpec(kind: .copy, sources: [f], destination: link), context: ctx)
        #expect(try Data(contentsOf: f) == Data("keepme".utf8))                    // source not deleted through the alias
        #expect(FileManager.default.fileExists(atPath: real.appendingPathComponent("f 2.txt").path))
    }

    @Test func batchKeepBothDistinctNamesNoCollision() async throws {
        // Data safety hardening (review MEDIUM): two same-named sources in a batch keepBoth must not compute one target name and overwrite each other.
        let dstDir = try Self.tempDir(), srcA = try Self.tempDir(), srcB = try Self.tempDir()
        defer { for u in [dstDir, srcA, srcB] { try? FileManager.default.removeItem(at: u) } }
        try Data("A".utf8).write(to: srcA.appendingPathComponent("dup.txt"))
        try Data("B".utf8).write(to: srcB.appendingPathComponent("dup.txt"))
        try Data("existing".utf8).write(to: dstDir.appendingPathComponent("dup.txt"))
        let ctx = Self.makeContext { c in
            Dictionary(uniqueKeysWithValues: c.map { ($0.source, ConflictDecision.keepBoth) })
        }
        _ = try await TransferNode().execute(
            OperationSpec(kind: .copy,
                          sources: [srcA.appendingPathComponent("dup.txt"), srcB.appendingPathComponent("dup.txt")],
                          destination: dstDir),
            context: ctx)
        let names = try FileManager.default.contentsOfDirectory(atPath: dstDir.path).sorted()
        #expect(names == ["dup 2.txt", "dup 3.txt", "dup.txt"])   // each gets its own name, none overwritten
        let contents = Set(names.compactMap { try? Data(contentsOf: dstDir.appendingPathComponent($0)) })
        #expect(contents.contains(Data("A".utf8)) && contents.contains(Data("B".utf8))
                && contents.contains(Data("existing".utf8)))
    }

    @Test func batchSameNameIntoEmptyDirAutoDisambiguates() async throws {
        // Data safety hardening (follow-up MEDIUM): two same-named sources from different directories copied into an **empty** target directory (zero disk conflicts,
        // no panel) must also each get a distinct name, never overwriting or losing each other.
        let dstDir = try Self.tempDir(), srcA = try Self.tempDir(), srcB = try Self.tempDir()
        defer { for u in [dstDir, srcA, srcB] { try? FileManager.default.removeItem(at: u) } }
        try Data("A".utf8).write(to: srcA.appendingPathComponent("dup.txt"))
        try Data("B".utf8).write(to: srcB.appendingPathComponent("dup.txt"))
        // The decision callback should not fire (an empty target directory has no disk conflicts)
        let ctx = Self.makeContext { _ in Issue.record("An empty directory should not raise a conflict"); return [:] }
        _ = try await TransferNode().execute(
            OperationSpec(kind: .copy,
                          sources: [srcA.appendingPathComponent("dup.txt"), srcB.appendingPathComponent("dup.txt")],
                          destination: dstDir),
            context: ctx)
        let names = try FileManager.default.contentsOfDirectory(atPath: dstDir.path).sorted()
        #expect(names == ["dup 2.txt", "dup.txt"])   // first keeps its name, second is auto-numbered
        let contents = Set(names.compactMap { try? Data(contentsOf: dstDir.appendingPathComponent($0)) })
        #expect(contents.contains(Data("A".utf8)) && contents.contains(Data("B".utf8)))
    }

    // MARK: Move (same-volume rename) and duplicate

    @Test func moveSameVolumeRenames() async throws {
        let src = try Self.tempDir(), dst = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        try Data("m".utf8).write(to: src.appendingPathComponent("f.txt"))
        _ = try await TransferNode().execute(
            OperationSpec(kind: .move, sources: [src.appendingPathComponent("f.txt")], destination: dst),
            context: Self.makeContext())
        #expect(!FileManager.default.fileExists(atPath: src.appendingPathComponent("f.txt").path))
        #expect(FileManager.default.fileExists(atPath: dst.appendingPathComponent("f.txt").path))
    }

    @Test func duplicateNeverConflicts() async throws {
        let src = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: src) }
        try Data("dup".utf8).write(to: src.appendingPathComponent("f.txt"))
        // If the decision callback fires the contract is broken (duplicate is always keepBoth-named and raises no conflict)
        let ctx = Self.makeContext { _ in
            Issue.record("duplicate should not trigger conflict resolution")
            return nil
        }
        _ = try await TransferNode().execute(
            OperationSpec(kind: .duplicate, sources: [src.appendingPathComponent("f.txt")]),
            context: ctx)
        #expect(try Data(contentsOf: src.appendingPathComponent("f 2.txt")) == Data("dup".utf8))
    }

    // MARK: Cancellation and error classification

    @Test func cancelledTaskThrowsCancellation() async throws {
        let src = try Self.tempDir(), dst = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        try Data("c".utf8).write(to: src.appendingPathComponent("f.txt"))
        let task = Task {
            try await TransferNode().execute(
                OperationSpec(kind: .copy, sources: [src.appendingPathComponent("f.txt")], destination: dst),
                context: Self.makeContext())
        }
        task.cancel()
        do {
            _ = try await task.value
            // Race: finishing before the cancel takes effect is a valid terminal state too, but the target must be complete
            let d = try Data(contentsOf: dst.appendingPathComponent("f.txt"))
            #expect(d == Data("c".utf8))
        } catch is CancellationError {
            // No partial output left after cancellation
            #expect(!FileManager.default.fileExists(atPath: dst.appendingPathComponent("f.txt").path))
        }
    }

    @Test func invalidSpecIsLogicError() async {
        do {
            _ = try await TransferNode().execute(
                OperationSpec(kind: .copy, sources: [], destination: nil),
                context: Self.makeContext())
            Issue.record("Expected an error")
        } catch let e as any ClassifiedError {
            #expect(e.errorClass == .logic)
        } catch {
            Issue.record("Unclassified error (violates P6.4):\(error)")
        }
    }
}
