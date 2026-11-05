import AppKit
import ArchiveEngine
import ArchivePasswords
import HSpaceContracts
import HSpaceTestSupport
import Testing
@testable import HSpaceApp

private final class MemoryStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    var stored: Data? { lock.withLock { data } }
    func read() throws -> Data? { lock.withLock { data } }
    func write(_ data: Data) throws { lock.withLock { self.data = data } }
    func delete() throws { lock.withLock { data = nil } }
}

/// With real encrypted zips, and the list in memory: tests never touch the Keychain.
@MainActor @Suite struct ArchivePasswordResolverTests {
    private func encryptedZip(password: String, in dir: URL) async throws -> URL {
        let file = dir.appendingPathComponent("secret.txt")
        try FaultFixture.write(Data("classified".utf8), to: file)
        let receipt = try await ArchiveEngineNode().execute(
            OperationSpec(kind: .compress, sources: [file], archiveOptions: ArchiveOptions(password: password)),
            context: NodeContext(operationID: UUID(), report: { _ in }, resolveConflicts: { _ in [:] }))
        return try #require(receipt.createdURLs.first)
    }

    /// Answers each question from `answers`, then cancels
    private func resolver(_ list: PasswordList, answers: [(String, Bool)],
                          asked: Box = Box()) -> ArchivePasswordResolver {
        ArchivePasswordResolver(list: list) { _, retry in
            defer { asked.retries.append(retry) }
            guard asked.retries.count < answers.count else { return nil }
            let answer = answers[asked.retries.count]
            return (answer.0, answer.1)
        }
    }

    final class Box {
        var retries: [Bool] = []
    }

    @Test func aPlainArchiveNeedsNothing() async throws {
        let dir = try FaultFixture.tempDir("hspace-resolve")
        defer { FaultFixture.remove(dir) }
        let archive = dir.appendingPathComponent("plain.tar")
        let asked = Box()

        let decision = try await resolver(PasswordList(store: MemoryStore()), answers: [], asked: asked).resolve(archive)

        #expect(decision == .notNeeded)
        #expect(asked.retries.isEmpty)
    }

    @Test func aSavedPasswordOpensWithoutAsking() async throws {
        let dir = try FaultFixture.tempDir("hspace-resolve")
        defer { FaultFixture.remove(dir) }
        let archive = try await encryptedZip(password: "saved", in: dir)
        let list = PasswordList(store: MemoryStore())
        try list.add(label: "Wrong one", password: "other")
        try list.add(label: "Right one", password: "saved")
        let asked = Box()

        let decision = try await resolver(list, answers: [], asked: asked).resolve(archive)

        #expect(decision == .password("saved"))
        #expect(asked.retries.isEmpty)
    }

    @Test func aWrongAnswerAsksAgainAndNothingIsSaved() async throws {
        let dir = try FaultFixture.tempDir("hspace-resolve")
        defer { FaultFixture.remove(dir) }
        let archive = try await encryptedZip(password: "right", in: dir)
        let store = MemoryStore()
        let asked = Box()

        let decision = try await resolver(PasswordList(store: store), answers: [("wrong", true), ("right", false)],
                                          asked: asked).resolve(archive)

        #expect(decision == .password("right"))
        #expect(asked.retries == [false, true])
        #expect(store.stored == nil)
    }

    @Test func rememberSavesOnlyAPasswordThatWorked() async throws {
        let dir = try FaultFixture.tempDir("hspace-resolve")
        defer { FaultFixture.remove(dir) }
        let archive = try await encryptedZip(password: "right", in: dir)
        let list = PasswordList(store: MemoryStore())

        _ = try await resolver(list, answers: [("wrong", true), ("right", true)]).resolve(archive)

        #expect(try list.load().map(\.password) == ["right"])
        #expect(try list.load().map(\.label) == [archive.lastPathComponent])
    }

    @Test func cancellingTheDialogIsADecision() async throws {
        let dir = try FaultFixture.tempDir("hspace-resolve")
        defer { FaultFixture.remove(dir) }
        let archive = try await encryptedZip(password: "right", in: dir)

        let decision = try await resolver(PasswordList(store: MemoryStore()), answers: []).resolve(archive)

        #expect(decision == .cancelled)
    }

    @Test func thePasswordReachesTheBrowserOnceAndCancellingStopsIt() async throws {
        let dir = try FaultFixture.tempDir("hspace-resolve")
        defer { FaultFixture.remove(dir) }
        let archive = try await encryptedZip(password: "right", in: dir)
        let model = ArchiveBrowserModel(archive: archive)
        defer { model.discardAll() }
        try await model.load()
        let node = try #require(model.root?.children.first)

        var asks = 0
        model.unlock = { _ in
            asks += 1
            return asks == 1 ? .cancelled : .password("right")
        }
        await #expect(throws: CancellationError.self) { _ = try await model.previewURLs([node]) }

        let urls = try await model.previewURLs([node])
        #expect(try String(contentsOf: urls[0], encoding: .utf8) == "classified")
        let staged = try await model.stage([node])
        #expect(try String(contentsOf: staged.items[0], encoding: .utf8) == "classified")
        #expect(asks == 2)
    }

    @Test func theCompressionPreferenceDefaultsToNormal() {
        #expect(Preferences.archiveCompressionOptions.map(\.id) == ArchiveCompression.allCases.map(\.rawValue))
        #expect(ArchiveCompression(rawValue: "normal") == .normal)
    }
}
