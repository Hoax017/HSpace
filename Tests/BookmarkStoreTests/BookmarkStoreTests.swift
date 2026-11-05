import Testing
import HSpaceTestSupport
import Foundation
import BookmarkStore

/// Black-box acceptance: real temp directory (no fakes or mocks)
@Suite struct BookmarkStoreTests {
    func makeStore() throws -> (BookmarkStore, URL, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hspace-bm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("target-folder")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return (BookmarkStore(directory: dir), dir, target)
    }

    @Test func addResolveRoundTrip() async throws {
        let (store, dir, target) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = try await store.add(target)
        #expect(item.name == "target-folder")
        let resolved = store.resolve(item)
        #expect(resolved?.standardizedFileURL.path == target.standardizedFileURL.path)
    }

    @Test func persistenceSurvivesReload() async throws {
        let (store, dir, target) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.add(target, name: "Résumé Ünï")
        // A new instance reloads from disk (cross-launch persistence acceptance)
        let store2 = BookmarkStore(directory: dir)
        let items = await store2.all()
        #expect(items.count == 1)
        #expect(items.first?.name == "Résumé Ünï")
    }

    @Test func removeRenameMove() async throws {
        let (store, dir, target) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try await store.add(target, name: "A")
        let b = try await store.add(target, name: "B")
        try await store.rename(a.id, to: "A2")
        try await store.move(from: 1, to: 0)
        var items = await store.all()
        #expect(items.map(\.name) == ["B", "A2"])
        try await store.remove(b.id)
        items = await store.all()
        #expect(items.map(\.name) == ["A2"])
    }

    // MARK: Start-location seeds (seedIfEmpty)

    /// First write: seed injects the given directories into an empty archive
    @Test func seedFirstTimeWrites() async throws {
        let (store, dir, target) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        await store.seedIfEmpty([(target, "Seed")])
        let items = await store.all()
        #expect(items.count == 1)
        #expect(items.first?.name == "Seed")
    }

    /// No repeats: calling again on the same instance, or reloading across instances with the seeded flag persisted, never seeds again
    @Test func seedSecondTimeNoDuplicate() async throws {
        let (store, dir, target) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        await store.seedIfEmpty([(target, "Seed")])
        await store.seedIfEmpty([(target, "Seed")])
        #expect(await store.all().count == 1)
        // After the user removes a seed, reloading across instances must not seed again (the seeded flag is persisted)
        let only = await store.all()[0]
        try await store.remove(only.id)
        let store2 = BookmarkStore(directory: dir)
        await store2.seedIfEmpty([(target, "Seed")])
        #expect(await store2.all().isEmpty)
    }

    /// No seeding when entries exist: an existing user bookmark skips seed injection
    @Test func seedSkippedWhenItemsExist() async throws {
        let (store, dir, target) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await store.add(target, name: "User Bookmark")
        await store.seedIfEmpty([(target, "Seed")])
        let items = await store.all()
        #expect(items.count == 1)
        #expect(items.first?.name == "User Bookmark")
    }

    /// Backward compatibility: an old plain-array archive (no seeded field) with items counts as seeded and is not polluted by seeds
    @Test func legacyArchiveTreatedAsSeeded() async throws {
        let (store, dir, target) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Hand-write an old-format bookmarks.json (plain [BookmarkItem] array)
        let data = try target.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let legacy = [BookmarkItem(name: "Old Bookmark", bookmarkData: data)]
        let json = try JSONEncoder().encode(legacy)
        try json.write(to: dir.appendingPathComponent("bookmarks.json"), options: .atomic)
        _ = store  // a new instance reads the old archive
        let store2 = BookmarkStore(directory: dir)
        await store2.seedIfEmpty([(target, "Seed")])
        let items = await store2.all()
        #expect(items.count == 1)
        #expect(items.first?.name == "Old Bookmark")
    }

    /// I-14 seed restore: existing targets (deduped by resolved path) are skipped, only missing ones are added; calling again is an idempotent 0 additions
    @Test func restoreMissingSeedsMergesOnlyAbsent() async throws {
        let (store, dir, target) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await store.add(target, name: "Existing")
        let other = dir.appendingPathComponent("other-seed", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let added = await store.restoreMissingSeeds([(target, "Duplicate Seed"), (other, "New Seed")])
        #expect(added == 1)
        let items = await store.all()
        #expect(items.count == 2)
        #expect(items.map(\.name).contains("New Seed"))
        let again = await store.restoreMissingSeeds([(target, "Duplicate Seed"), (other, "New Seed")])
        #expect(again == 0)
    }
}

private func keptFiles(_ dir: URL, _ name: String) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("\(name).corrupt-") }
}

/// D1: a file that cannot be loaded is kept aside and reported, never overwritten.
@Suite struct BookmarkStoreCorruptFileTests {
    let garbage = Data("{ not json".utf8)

    func corruptDirectory() throws -> (dir: URL, file: URL, target: URL) {
        let dir = try FaultFixture.tempDir("hspace-bm")
        let file = dir.appendingPathComponent("bookmarks.json")
        try FaultFixture.write(garbage, to: file)
        let target = dir.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return (dir, file, target)
    }

    @Test func corruptFileIsKeptAsideAndReported() async throws {
        let (dir, file, target) = try corruptDirectory()
        defer { FaultFixture.remove(dir) }
        let store = BookmarkStore(directory: dir)
        #expect(await store.all().isEmpty)
        let kept = try #require(try keptFiles(dir, "bookmarks.json").first)
        #expect(try Data(contentsOf: kept) == garbage)
        let problem = try #require(await store.takeProblem())
        #expect(problem.localizedDescription.contains(kept.lastPathComponent))
        #expect(await store.takeProblem() == nil, "reported once")

        try await store.add(target)
        #expect(try Data(contentsOf: kept) == garbage)
        #expect(try Data(contentsOf: file) != garbage)
        #expect(await BookmarkStore(directory: dir).all().count == 1)
    }

    @Test func unreadableFileIsKeptAside() async throws {
        let (dir, file, target) = try corruptDirectory()
        defer { FaultFixture.remove(dir) }
        let store = BookmarkStore(directory: dir)
        try await FaultFixture.withMode(0o000, on: file) {
            #expect(await store.all().isEmpty)
        }
        #expect(await store.takeProblem() != nil)
        try await store.add(target)
        let kept = try #require(try keptFiles(dir, "bookmarks.json").first)
        chmod(kept.path, 0o644)
        #expect(try Data(contentsOf: kept) == garbage)
    }

    @Test func fileThatCannotBeMovedBlocksWritesUntilItCan() async throws {
        let (dir, _, target) = try corruptDirectory()
        defer { FaultFixture.remove(dir) }
        let store = BookmarkStore(directory: dir)
        try await FaultFixture.withReadOnly(dir) {
            #expect(await store.all().isEmpty)
            #expect(await store.takeProblem() != nil)
            await #expect(throws: BookmarkError.self) { try await store.add(target) }
        }
        #expect(try keptFiles(dir, "bookmarks.json").isEmpty, "nothing moved yet")
        // Writable again: the next write moves the original aside first
        try await store.add(target)
        let kept = try #require(try keptFiles(dir, "bookmarks.json").first)
        #expect(try Data(contentsOf: kept) == garbage)
        let located = try #require(await store.takeProblem())
        #expect(located.localizedDescription.contains(kept.lastPathComponent))
    }

    @Test func missingFileIsNotAProblem() async throws {
        let dir = try FaultFixture.tempDir("hspace-bm")
        defer { FaultFixture.remove(dir) }
        let store = BookmarkStore(directory: dir)
        #expect(await store.all().isEmpty)
        #expect(await store.takeProblem() == nil)
    }
}
