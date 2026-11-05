import Testing
import HSpaceTestSupport
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

private func keptFiles(_ dir: URL, _ name: String) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("\(name).corrupt-") }
}

/// D1: a file that cannot be loaded is kept aside and reported, never overwritten.
@Suite struct StashStoreCorruptFileTests {
    let garbage = Data("{ not json".utf8)

    func corruptDirectory() throws -> (dir: URL, file: URL, target: URL) {
        let dir = try FaultFixture.tempDir("hspace-st")
        let file = dir.appendingPathComponent("stash.json")
        try FaultFixture.write(garbage, to: file)
        let target = dir.appendingPathComponent("target.txt")
        try FaultFixture.write(to: target)
        return (dir, file, target)
    }

    @Test func corruptFileIsKeptAsideAndReported() async throws {
        let (dir, file, target) = try corruptDirectory()
        defer { FaultFixture.remove(dir) }
        let store = StashStore(directory: dir)
        #expect(await store.all().isEmpty)
        let kept = try #require(try keptFiles(dir, "stash.json").first)
        #expect(try Data(contentsOf: kept) == garbage)
        let problem = try #require(await store.takeProblem())
        #expect(problem.localizedDescription.contains(kept.lastPathComponent))
        #expect(await store.takeProblem() == nil, "reported once")

        try await store.add([target])
        #expect(try Data(contentsOf: kept) == garbage)
        #expect(try Data(contentsOf: file) != garbage)
        #expect(await StashStore(directory: dir).all().count == 1)
    }

    @Test func unreadableFileIsKeptAside() async throws {
        let (dir, file, target) = try corruptDirectory()
        defer { FaultFixture.remove(dir) }
        let store = StashStore(directory: dir)
        try await FaultFixture.withMode(0o000, on: file) {
            #expect(await store.all().isEmpty)
        }
        #expect(await store.takeProblem() != nil)
        try await store.add([target])
        let kept = try #require(try keptFiles(dir, "stash.json").first)
        chmod(kept.path, 0o644)
        #expect(try Data(contentsOf: kept) == garbage)
    }

    @Test func fileThatCannotBeMovedBlocksWritesUntilItCan() async throws {
        let (dir, _, target) = try corruptDirectory()
        defer { FaultFixture.remove(dir) }
        let store = StashStore(directory: dir)
        try await FaultFixture.withReadOnly(dir) {
            #expect(await store.all().isEmpty)
            #expect(await store.takeProblem() != nil)
            await #expect(throws: StashError.self) { try await store.add([target]) }
        }
        #expect(try keptFiles(dir, "stash.json").isEmpty, "nothing moved yet")
        let another = dir.appendingPathComponent("another.txt")
        try FaultFixture.write(to: another)
        try await store.add([another])
        let kept = try #require(try keptFiles(dir, "stash.json").first)
        #expect(try Data(contentsOf: kept) == garbage)
        let located = try #require(await store.takeProblem())
        #expect(located.localizedDescription.contains(kept.lastPathComponent))
    }

    @Test func errorsKeepTheirMessageAsPlainErrors() async throws {
        let dir = try FaultFixture.tempDir("hspace-st")
        defer { FaultFixture.remove(dir) }
        let target = dir.appendingPathComponent("target.txt")
        try FaultFixture.write(to: target)
        let store = StashStore(directory: dir)
        try await FaultFixture.withReadOnly(dir) {
            do {
                try await store.add([target])
                Issue.record("expected a failure")
            } catch {
                // The shelf shows `error.localizedDescription` on `any Error`
                #expect(error.localizedDescription.contains("Could not save stash shelf"))
            }
        }
    }

    @Test func missingFileIsNotAProblem() async throws {
        let dir = try FaultFixture.tempDir("hspace-st")
        defer { FaultFixture.remove(dir) }
        let store = StashStore(directory: dir)
        #expect(await store.all().isEmpty)
        #expect(await store.takeProblem() == nil)
    }
}
