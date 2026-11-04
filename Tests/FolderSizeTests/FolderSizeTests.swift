import Testing
import Foundation
import FolderSize
import HSpaceContracts

/// Black-box acceptance: only through the Contract public surface, asserting on real temp fixture trees (no fakes or mocks).
/// Assertion basis: totalFileAllocatedSize is the block-aligned real allocation >= logical bytes, so lower bounds are used rather than equality.
@Suite struct FolderSizeTests {
    static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hspace-fs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func sumsNestedTreeAtLeastLogicalBytes() async throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a/b"),
                                                withIntermediateDirectories: true)
        try Data(count: 100_000).write(to: root.appendingPathComponent("top.bin"))
        try Data(count: 50_000).write(to: root.appendingPathComponent("a/mid.bin"))
        try Data(count: 25_000).write(to: root.appendingPathComponent("a/b/deep.bin"))

        let total = try await FolderSize().size(of: root)
        #expect(total >= 175_000)                    // allocation >= logical bytes
        #expect(total < 175_000 + 3 * 1_048_576)     // and not absurd (within block-alignment slack for 3 files)
    }

    @Test func singleRegularFileReturnsItsSize() async throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let f = root.appendingPathComponent("one.bin")
        try Data(count: 4096).write(to: f)
        let total = try await FolderSize().size(of: f)
        #expect(total >= 4096)
    }

    @Test func emptyFolderIsZero() async throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await FolderSize().size(of: root) == 0)
    }

    @Test func cacheServesStaleUntilInvalidated() async throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(count: 10_000).write(to: root.appendingPathComponent("f1.bin"))

        let node = FolderSize()
        let first = try await node.size(of: root)

        // Tree grew but no invalidation → cache hit returns the old value (derived cache contract)
        try Data(count: 200_000).write(to: root.appendingPathComponent("f2.bin"))
        #expect(try await node.size(of: root) == first)

        // Recomputed after invalidation → sees the new file
        await node.invalidate(root)
        let refreshed = try await node.size(of: root)
        #expect(refreshed >= first + 200_000)
    }

    @Test func hiddenFilesAreCounted() async throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(count: 30_000).write(to: root.appendingPathComponent(".hidden.bin"))
        #expect(try await FolderSize().size(of: root) >= 30_000)
    }

    @Test func missingPathThrowsClassified() async {
        let bogus = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        do {
            _ = try await FolderSize().size(of: bogus)
            Issue.record("Expected an error")
        } catch let e as any ClassifiedError {
            #expect(e.errorClass == .external || e.errorClass == .transient)
        } catch {
            Issue.record("Unclassified error (violates P6.4):\(error)")
        }
    }

    @Test func cancellationStopsEnumeration() async throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        // Lay out a tree of some size so the cancel has a chance to land before completion
        for i in 0..<40 {
            let d = root.appendingPathComponent("d\(i)")
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            for j in 0..<25 {
                try Data(count: 64).write(to: d.appendingPathComponent("f\(j)"))
            }
        }
        let node = FolderSize()
        let task = Task { try await node.size(of: root) }
        task.cancel()
        do {
            // Race: finishing before the cancel takes effect is a valid terminal state too; the result must then be complete
            let total = try await task.value
            #expect(total >= 40 * 25 * 64)
        } catch is CancellationError {
            // Cooperative cancellation took effect: valid
        } catch {
            Issue.record("Cancellation should throw CancellationError, got:\(error)")
        }
    }
}
