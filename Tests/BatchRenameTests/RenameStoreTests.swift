import BatchRename
import Foundation
import HSpaceTestSupport
import Testing

@Suite struct RenameStoreTests {
    private let steps: [RenameStep] = [.insert(text: "x", position: .prefix)]

    private func journal() -> RenameJournal {
        RenameJournal(entries: [RenameJournalEntry(from: "/a", to: "/b")])
    }

    @Test func presetsPersistAndAreReplacedByName() async throws {
        let dir = try FaultFixture.tempDir("hspace-rename-store")
        defer { FaultFixture.remove(dir) }
        let store = RenameStore(directory: dir)
        try await store.savePreset(named: "b", steps: steps)
        try await store.savePreset(named: "a", steps: [])
        try await store.savePreset(named: "b", steps: [])
        let reopened = await RenameStore(directory: dir).presets()
        #expect(reopened.map(\.name) == ["a", "b"])
        #expect(reopened[1].steps.isEmpty)
    }

    @Test func aPresetCanBeDeleted() async throws {
        let dir = try FaultFixture.tempDir("hspace-rename-store")
        defer { FaultFixture.remove(dir) }
        let store = RenameStore(directory: dir)
        try await store.savePreset(named: "a", steps: steps)
        let preset = try #require(await store.presets().first)
        try await store.deletePreset(id: preset.id)
        #expect(await RenameStore(directory: dir).presets().isEmpty)
    }

    @Test func theLogIsNewestFirstAndKnowsWhatWasReversed() async throws {
        let dir = try FaultFixture.tempDir("hspace-rename-store")
        defer { FaultFixture.remove(dir) }
        let store = RenameStore(directory: dir)
        let first = journal(), second = journal(), undo = journal()
        await store.record(first)
        await store.record(second)
        await store.record(undo, reverses: first.id)
        let log = await RenameStore(directory: dir).log()
        #expect(log.map(\.id) == [undo.id, second.id, first.id])
        #expect(log.map(\.isReversed) == [false, false, true])
        #expect(log[0].reverses == first.id)
    }

    @Test func theLogIsBounded() async throws {
        let dir = try FaultFixture.tempDir("hspace-rename-store")
        defer { FaultFixture.remove(dir) }
        let store = RenameStore(directory: dir)
        for _ in 0...RenameStore.logLimit { await store.record(journal()) }
        #expect(await store.log().count == RenameStore.logLimit)
    }

    @Test func aDamagedFileIsKeptAsideAndReported() async throws {
        let dir = try FaultFixture.tempDir("hspace-rename-store")
        defer { FaultFixture.remove(dir) }
        try FaultFixture.write(Data("{not json".utf8), to: dir.appendingPathComponent("rename-log.json"))
        let store = RenameStore(directory: dir)
        let problem = await store.takeProblem()
        #expect(problem?.localizedDescription.contains("kept at") == true)
        await store.record(journal())
        #expect(await store.log().count == 1)
        let kept = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".corrupt-") }
        #expect(kept.count == 1)
        #expect(try Data(contentsOf: dir.appendingPathComponent(kept[0])) == Data("{not json".utf8))
    }

    @Test func aFailedLogWriteIsReportedNotThrown() async throws {
        let dir = try FaultFixture.tempDir("hspace-rename-store")
        defer { FaultFixture.remove(dir) }
        let store = RenameStore(directory: dir)
        _ = await store.log()
        try await FaultFixture.withReadOnly(dir) {
            await store.record(journal())
        }
        let problem = await store.takeProblem()
        #expect(problem?.localizedDescription.contains("Could not save") == true)
    }

    @Test func aFailedPresetWriteThrows() async throws {
        let dir = try FaultFixture.tempDir("hspace-rename-store")
        defer { FaultFixture.remove(dir) }
        let store = RenameStore(directory: dir)
        try await FaultFixture.withReadOnly(dir) {
            await #expect(throws: BatchRenameError.self) { try await store.savePreset(named: "a", steps: steps) }
        }
    }
}
