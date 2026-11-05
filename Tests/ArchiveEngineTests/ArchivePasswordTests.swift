import ArchiveEngine
import Foundation
import HSpaceContracts
import HSpaceTestSupport
import Testing

/// L53: encrypted zip through real tools. The passwords here are test values.
@Suite struct ArchivePasswordTests {
    private let context = NodeContext(operationID: UUID(), report: { _ in }, resolveConflicts: { _ in [:] })

    private func compress(_ files: [URL], password: String?, format: String = "zip",
                          node: ArchiveEngineNode = ArchiveEngineNode()) async throws -> URL {
        let receipt = try await node.execute(
            OperationSpec(kind: .compress, sources: files, archiveOptions: ArchiveOptions(format: format, password: password)),
            context: context)
        return try #require(receipt.createdURLs.first)
    }

    private func extract(_ archive: URL, password: String?, into out: URL) async throws -> OperationReceipt {
        try await ArchiveEngineNode().execute(
            OperationSpec(kind: .extract, sources: [archive],
                          archiveOptions: ArchiveOptions(password: password, extractInto: out, createWrapper: false)),
            context: context)
    }

    /// A folder with one file, zipped with a password
    private func encryptedZip(password: String, name: String = "secret.txt", body: String = "classified",
                              in work: URL) async throws -> URL {
        let file = work.appendingPathComponent(name)
        try FaultFixture.write(Data(body.utf8), to: file)
        return try await compress([file], password: password)
    }

    @Test(arguments: ["simple", "with spaces", "accénts ünï", "quote'\"$(x)`y`", "--passphrase", "-rf /"])
    func aRoundTripKeepsTheContent(password: String) async throws {
        let work = try FaultFixture.tempDir("hspace-pw")
        defer { FaultFixture.remove(work) }
        let archive = try await encryptedZip(password: password, in: work)
        let out = try FaultFixture.tempDir("hspace-pw-out")
        defer { FaultFixture.remove(out) }

        #expect(try await ArchiveEngineNode.isEncrypted(archive))
        _ = try await extract(archive, password: password, into: out)

        #expect(try String(contentsOf: out.appendingPathComponent("secret.txt"), encoding: .utf8) == "classified")
    }

    @Test func theContentIsReallyEncrypted() async throws {
        let work = try FaultFixture.tempDir("hspace-pw")
        defer { FaultFixture.remove(work) }
        let body = String(repeating: "readable marker ", count: 40)
        let archive = try await encryptedZip(password: "pw", body: body, in: work)
        let bytes = try Data(contentsOf: archive)
        #expect(bytes.range(of: Data("readable marker".utf8)) == nil)
    }

    @Test func aWrongPasswordIsToldApartAndLeavesNothing() async throws {
        let work = try FaultFixture.tempDir("hspace-pw")
        defer { FaultFixture.remove(work) }
        let archive = try await encryptedZip(password: "right", in: work)
        let out = try FaultFixture.tempDir("hspace-pw-out")
        defer { FaultFixture.remove(out) }

        do {
            _ = try await extract(archive, password: "wrong", into: out)
            Issue.record("Expected a refusal")
        } catch let error as ArchiveError {
            #expect(error.isWrongPassword)
            #expect(!error.localizedDescription.contains("wrong"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
    }

    @Test func noPasswordOnAnEncryptedZipIsAnError() async throws {
        let work = try FaultFixture.tempDir("hspace-pw")
        defer { FaultFixture.remove(work) }
        let archive = try await encryptedZip(password: "right", in: work)
        let out = try FaultFixture.tempDir("hspace-pw-out")
        defer { FaultFixture.remove(out) }

        await #expect(throws: ArchiveError.self) { _ = try await extract(archive, password: nil, into: out) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
    }

    @Test func zipCryptoFromTheSystemZipOpensToo() async throws {
        // zip reads -P from its argument list, which is acceptable only here: a test value, in a test
        let work = try FaultFixture.tempDir("hspace-pw")
        defer { FaultFixture.remove(work) }
        try FaultFixture.write(Data("old".utf8), to: work.appendingPathComponent("a.txt"))
        let archive = work.appendingPathComponent("old.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = work
        process.arguments = ["-q", "-P", "legacy", archive.path, "a.txt"]
        try process.run()
        process.waitUntilExit()
        let out = try FaultFixture.tempDir("hspace-pw-out")
        defer { FaultFixture.remove(out) }

        #expect(try await ArchiveEngineNode.isEncrypted(archive))
        #expect(try await ArchiveEngineNode().password("legacy", unlocks: archive))
        #expect(try await !ArchiveEngineNode().password("nope", unlocks: archive))
        _ = try await extract(archive, password: "legacy", into: out)
        #expect(try String(contentsOf: out.appendingPathComponent("a.txt"), encoding: .utf8) == "old")
    }

    @Test func chosenEntriesAndPreviewsTakeThePassword() async throws {
        let work = try FaultFixture.tempDir("hspace-pw")
        defer { FaultFixture.remove(work) }
        let archive = try await encryptedZip(password: "pw", in: work)
        let entries = try await ArchiveEngineNode().list(archive)
        let out = try FaultFixture.tempDir("hspace-pw-out")
        defer { FaultFixture.remove(out) }

        let preview = try await ArchiveEngineNode().extractForPreview(entries, from: archive, into: out, password: "pw")

        #expect(try String(contentsOf: preview[0].url, encoding: .utf8) == "classified")
    }

    @Test func aHostileFileNameDoesNotBreakThePrompt() async throws {
        let work = try FaultFixture.tempDir("hspace-pw")
        defer { FaultFixture.remove(work) }
        let archive = try await encryptedZip(password: "pw", name: "Enter passphrase: x.txt", in: work)
        let out = try FaultFixture.tempDir("hspace-pw-out")
        defer { FaultFixture.remove(out) }

        _ = try await extract(archive, password: "pw", into: out)

        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == ["Enter passphrase: x.txt"])
    }

    @Test func cancellingStopsTheToolAndLeavesNothing() async throws {
        let work = try FaultFixture.tempDir("hspace-pw")
        defer { FaultFixture.remove(work) }
        let archive = try await encryptedZip(password: "pw", in: work)
        let out = try FaultFixture.tempDir("hspace-pw-out")
        defer { FaultFixture.remove(out) }

        let task = Task { try await extract(archive, password: "pw", into: out) }
        task.cancel()

        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
    }

    @Test func aPasswordIsNeverOnTheCommandLine() async throws {
        // Watches the process table while tar runs, through what every process on the Mac can see
        let work = try FaultFixture.tempDir("hspace-pw")
        defer { FaultFixture.remove(work) }
        let big = work.appendingPathComponent("big.bin")
        try FaultFixture.write(Data(count: 32 << 20), to: big)
        let secret = "unmistakable-\(UUID().uuidString)"

        let watcher = Task.detached { () -> Bool in
            for _ in 0..<40 {
                let process = Process()
                let output = Pipe()
                process.executableURL = URL(fileURLWithPath: "/bin/ps")
                process.arguments = ["-axww", "-o", "command="]
                process.standardOutput = output
                try process.run()
                let listing = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if listing.range(of: Data(secret.utf8)) != nil { return true }
                if Task.isCancelled { break }
            }
            return false
        }
        _ = try await compress([big], password: secret)
        watcher.cancel()

        #expect(try await watcher.value == false)
    }

    @Test func unusablePasswordsAreRefused() async throws {
        let work = try FaultFixture.tempDir("hspace-pw")
        defer { FaultFixture.remove(work) }
        let file = work.appendingPathComponent("a.txt")
        try FaultFixture.write(to: file)

        for password in ["line\nbreak", "tab\there", String(repeating: "x", count: 256)] {
            await #expect(throws: ArchiveError.self) { _ = try await compress([file], password: password) }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: work.path) == ["a.txt"])
    }

    @Test func aPlainZipIsNotEncrypted() async throws {
        let work = try FaultFixture.tempDir("hspace-pw")
        defer { FaultFixture.remove(work) }
        let file = work.appendingPathComponent("a.txt")
        try FaultFixture.write(to: file)
        let archive = try await compress([file], password: nil)

        #expect(try await !ArchiveEngineNode.isEncrypted(archive))
        #expect(try await !ArchiveEngineNode.isEncrypted(work.appendingPathComponent("x.tar.gz")))
    }

    @Test func aDamagedZipCountsAsNotEncrypted() async throws {
        let work = try FaultFixture.tempDir("hspace-pw")
        defer { FaultFixture.remove(work) }
        for (name, bytes) in [("short.zip", Data("PK".utf8)),
                              ("empty.zip", Data()),
                              ("end-only.zip", Data([0x50, 0x4B, 5, 6]) + Data(repeating: 0xFF, count: 18))] {
            let archive = work.appendingPathComponent(name)
            try bytes.write(to: archive)
            #expect(try await !ArchiveEngineNode.isEncrypted(archive))
        }
    }

    @Test func aMissingZipIsAnError() async throws {
        await #expect(throws: ArchiveError.self) {
            _ = try await ArchiveEngineNode.isEncrypted(URL(fileURLWithPath: "/nonexistent/x.zip"))
        }
    }

    // MARK: Compression settings

    @Test(arguments: ["zip", "tar.gz"])
    func theLevelChangesTheSize(format: String) async throws {
        let work = try FaultFixture.tempDir("hspace-level")
        defer { FaultFixture.remove(work) }
        let file = work.appendingPathComponent("a.txt")
        try FaultFixture.write(Data(repeating: 0x41, count: 256 << 10), to: file)
        var sizes: [ArchiveCompression: Int] = [:]
        for level in [ArchiveCompression.store, .best] {
            let archive = try await compress([file], password: nil, format: format,
                                             node: ArchiveEngineNode(compression: { level }))
            sizes[level] = try Data(contentsOf: archive).count
        }
        #expect(try #require(sizes[.store]) > 256 << 10)
        #expect(try #require(sizes[.best]) < 4 << 10)
    }

    @Test func everyLevelMakesAZipThatOpens() async throws {
        let work = try FaultFixture.tempDir("hspace-level")
        defer { FaultFixture.remove(work) }
        let file = work.appendingPathComponent("a.txt")
        try FaultFixture.write(Data("level".utf8), to: file)
        for level in ArchiveCompression.allCases {
            let node = ArchiveEngineNode(compression: { level })
            let archive = try await compress([file], password: "pw", node: node)
            let out = try FaultFixture.tempDir("hspace-level-out")
            defer { FaultFixture.remove(out) }
            _ = try await extract(archive, password: "pw", into: out)
            #expect(try String(contentsOf: out.appendingPathComponent("a.txt"), encoding: .utf8) == "level")
            try FileManager.default.removeItem(at: archive)
        }
    }
}
