import Testing
import Foundation
import StashStore

/// Black-box acceptance: real temp directory fixtures (no fakes or mocks)
@Suite struct StashStoreTests {
    /// Builds a temp fixture: storage directory + two real files + one real subdirectory
    func makeFixture() throws -> (StashStore, dir: URL, fileA: URL, fileB: URL, folder: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hspace-stash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileA = dir.appendingPathComponent("a.txt")
        let fileB = dir.appendingPathComponent("b.txt")
        try Data("A".utf8).write(to: fileA)
        try Data("B".utf8).write(to: fileB)
        let folder = dir.appendingPathComponent("sub-folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (StashStore(directory: dir), dir, fileA, fileB, folder)
    }

    @Test func addResolveRoundTrip() async throws {
        let (store, dir, fileA, _, folder) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Takes files as well as directories (unlike the bookmark group, which takes only directories)
        let added = try await store.add([fileA, folder])
        #expect(added.count == 2)
        let items = await store.all()
        #expect(items.count == 2)
        let resolved = items.compactMap { store.resolve($0)?.standardizedFileURL.path }
        #expect(resolved.contains(fileA.standardizedFileURL.path))
        #expect(resolved.contains(folder.standardizedFileURL.path))
    }

    @Test func dedupSamePath() async throws {
        let (store, dir, fileA, fileB, _) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.add([fileA])
        // Re-adding the same path (including duplicates within a batch) produces no new item
        let added = try await store.add([fileA, fileA, fileB])
        #expect(added.count == 1)
        let items = await store.all()
        #expect(items.count == 2)
    }

    @Test func removeAndClear() async throws {
        let (store, dir, fileA, fileB, folder) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let added = try await store.add([fileA, fileB, folder])
        try await store.remove(ids: [added[0].id])
        var items = await store.all()
        #expect(items.count == 2)
        #expect(!items.contains { $0.id == added[0].id })
        try await store.clear()
        items = await store.all()
        #expect(items.isEmpty)
    }

    @Test func persistenceSurvivesReload() async throws {
        let (store, dir, fileA, _, folder) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.add([fileA, folder])
        // A new instance reloads from disk (cross-launch persistence acceptance)
        let store2 = StashStore(directory: dir)
        let items = await store2.all()
        #expect(items.count == 2)
        let resolved = items.compactMap { store2.resolve($0)?.standardizedFileURL.path }
        #expect(resolved.contains(fileA.standardizedFileURL.path))
    }

    @Test func resolveMissingTargetReturnsNil() async throws {
        let (store, dir, fileA, _, _) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let added = try await store.add([fileA])
        try FileManager.default.removeItem(at: fileA)
        // Target deleted → resolve returns nil (the UI grays it out), the item itself remains
        #expect(store.resolve(added[0]) == nil)
        let items = await store.all()
        #expect(items.count == 1)
    }
}
