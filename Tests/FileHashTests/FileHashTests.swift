import CryptoKit
import FileHash
import Foundation
import HSpaceTestSupport
import Testing

private func run(_ files: [URL], _ algorithms: Set<HashAlgorithm> = Set(HashAlgorithm.allCases)) async throws -> [FileHashOutcome] {
    var outcomes: [FileHashOutcome] = []
    for try await event in FileHasher.hash(files, algorithms: algorithms) {
        if case .finished(let outcome) = event { outcomes.append(outcome) }
    }
    return outcomes
}

private func digest(_ outcome: FileHashOutcome) throws -> FileDigest { try outcome.result.get() }

@Suite struct HashingTests {
    @Test func knownVectors() async throws {
        let dir = try FaultFixture.tempDir("hspace-hash")
        defer { FaultFixture.remove(dir) }
        let file = dir.appendingPathComponent("abc")
        try FaultFixture.write(Data("abc".utf8), to: file)
        let value = try digest(try await run([file])[0])
        #expect(value.values[.md5] == "900150983cd24fb0d6963f7d28e17f72")
        #expect(value.values[.sha1] == "a9993e364706816aba3e25717850c26c9cd0d89d")
        #expect(value.values[.sha256] == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(value.byteCount == 3)
    }

    @Test func anEmptyFileHasADigest() async throws {
        let dir = try FaultFixture.tempDir("hspace-hash")
        defer { FaultFixture.remove(dir) }
        let file = dir.appendingPathComponent("empty")
        try FaultFixture.write(Data(), to: file)
        let value = try digest(try await run([file], [.md5])[0])
        #expect(value.values == [.md5: "d41d8cd98f00b204e9800998ecf8427e"])
    }

    @Test func aFileLargerThanOneChunkMatchesAOneShotDigest() async throws {
        let dir = try FaultFixture.tempDir("hspace-hash")
        defer { FaultFixture.remove(dir) }
        let file = dir.appendingPathComponent("big")
        let data = Data((0..<3_500_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try FaultFixture.write(data, to: file)
        let value = try digest(try await run([file], [.sha256])[0])
        #expect(value.values[.sha256] == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        #expect(value.byteCount == 3_500_000)
    }

    @Test func aLinkHashesItsTarget() async throws {
        let dir = try FaultFixture.tempDir("hspace-hash")
        defer { FaultFixture.remove(dir) }
        let file = dir.appendingPathComponent("abc"), link = dir.appendingPathComponent("link")
        try FaultFixture.write(Data("abc".utf8), to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let outcomes = try await run([file, link], [.md5])
        #expect(try digest(outcomes[0]) == digest(outcomes[1]))
    }

    @Test func progressCountsUpToTheTotal() async throws {
        let dir = try FaultFixture.tempDir("hspace-hash")
        defer { FaultFixture.remove(dir) }
        let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b")
        try FaultFixture.write(Data(count: 10), to: a)
        try FaultFixture.write(Data(count: 20), to: b)
        var seen: [HashProgress] = []
        for try await event in FileHasher.hash([a, b], algorithms: [.md5]) {
            if case .progress(let progress) = event { seen.append(progress) }
        }
        #expect(seen.map(\.current) == [a, b])
        #expect(seen.last?.bytesDone == 10)
        #expect(seen.last?.bytesTotal == 30)
        #expect(seen.last?.filesDone == 1)
    }
}

@Suite struct HashFailureTests {
    @Test func oneBadFileDoesNotStopTheOthers() async throws {
        let dir = try FaultFixture.tempDir("hspace-hash")
        defer { FaultFixture.remove(dir) }
        let good = dir.appendingPathComponent("good"), missing = dir.appendingPathComponent("missing")
        try FaultFixture.write(to: good)
        let outcomes = try await run([missing, dir, good])
        #expect(throws: FileHashError.self) { try outcomes[0].result.get() }
        #expect(throws: FileHashError.self) { try outcomes[1].result.get() }
        #expect(try digest(outcomes[2]).byteCount > 0)
    }

    @Test func noPermissionIsReportedForThatFile() async throws {
        let dir = try FaultFixture.tempDir("hspace-hash")
        defer { FaultFixture.remove(dir) }
        let file = dir.appendingPathComponent("secret")
        try FaultFixture.write(to: file)
        try await FaultFixture.withMode(0o000, on: file) {
            let outcomes = try await run([file])
            #expect(throws: FileHashError.self) { try outcomes[0].result.get() }
        }
    }

    @Test func aDanglingLinkIsReported() async throws {
        let dir = try FaultFixture.tempDir("hspace-hash")
        defer { FaultFixture.remove(dir) }
        let link = try FaultFixture.danglingLink(at: dir.appendingPathComponent("link"))
        let outcomes = try await run([link])
        #expect(throws: FileHashError.self) { try outcomes[0].result.get() }
    }

    @Test func cancellingEndsTheStreamEarly() async throws {
        let dir = try FaultFixture.tempDir("hspace-hash")
        defer { FaultFixture.remove(dir) }
        // Sparse: quick to make, and far too long to hash before the cancel lands
        let files = (0..<30).map { dir.appendingPathComponent("f\($0)") }
        for file in files {
            try FaultFixture.write(Data(), to: file)
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: 256 << 20)
            try handle.close()
        }
        let task = Task { () -> Int in
            var finished = 0
            for try await event in FileHasher.hash(files, algorithms: [.sha256]) {
                switch event {
                case .progress: withUnsafeCurrentTask { $0?.cancel() }
                case .finished: finished += 1
                }
            }
            return finished
        }
        #expect(try await task.value < files.count)
    }

    @Test func anEjectedVolumeIsReported() async throws {
        let volume = try ScratchVolume()
        let file = volume.url.appendingPathComponent("file")
        try FaultFixture.write(to: file)
        try volume.eject()
        let outcomes = try await run([file])
        #expect(throws: FileHashError.self) { try outcomes[0].result.get() }
    }
}

@Suite struct HashComparisonTests {
    private let digest = FileDigest(byteCount: 1, values: [.md5: "abc123", .sha256: "def456"])

    @Test func aPastedDigestMatchesWhateverItsCase() {
        #expect(FileHasher.match("  ABC123\n", in: digest) == .md5)
        #expect(FileHasher.match("def456", in: digest) == .sha256)
        #expect(FileHasher.match("abc12", in: digest) == nil)
        #expect(FileHasher.match("", in: digest) == nil)
    }

    @Test func theShapeOfADigestNamesItsAlgorithm() {
        #expect(FileHasher.algorithm(of: String(repeating: "a", count: 32)) == .md5)
        #expect(FileHasher.algorithm(of: String(repeating: "F", count: 40)) == .sha1)
        #expect(FileHasher.algorithm(of: " " + String(repeating: "0", count: 64)) == .sha256)
        #expect(FileHasher.algorithm(of: String(repeating: "g", count: 32)) == nil)
        #expect(FileHasher.algorithm(of: "abc") == nil)
    }

    @Test func comparingFiles() {
        let same = FileDigest(byteCount: 1, values: [.md5: "abc123"])
        let different = FileDigest(byteCount: 1, values: [.md5: "000000"])
        let longer = FileDigest(byteCount: 2, values: [.md5: "abc123"])
        let unrelated = FileDigest(byteCount: 1, values: [.sha1: "abc123"])
        #expect(FileHasher.allIdentical([digest, same]) == true)
        #expect(FileHasher.allIdentical([digest, same, different]) == false)
        #expect(FileHasher.allIdentical([digest, longer]) == false)
        #expect(FileHasher.allIdentical([digest, unrelated]) == nil)
        #expect(FileHasher.allIdentical([digest]) == nil)
    }
}
