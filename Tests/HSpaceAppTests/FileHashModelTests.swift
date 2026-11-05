import AppKit
import FileHash
import HSpaceTestSupport
import Testing
@testable import HSpaceApp

@MainActor @Suite struct FileHashModelTests {
    private let abcSHA256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    private func files(_ contents: [String]) throws -> (dir: URL, urls: [URL]) {
        let dir = try FaultFixture.tempDir("hspace-hash-model")
        let urls = contents.enumerated().map { dir.appendingPathComponent("f\($0.offset)") }
        for (url, text) in zip(urls, contents) { try FaultFixture.write(Data(text.utf8), to: url) }
        return (dir, urls)
    }

    @Test func identicalAndDifferentFilesAreSaid() async throws {
        let (dir, urls) = try files(["abc", "abc", "other"])
        defer { FaultFixture.remove(dir) }
        let same = FileHashModel(files: Array(urls[0...1]))
        await same.run()
        #expect(same.summary == L10n.t("hash.identical"))
        let different = FileHashModel(files: urls)
        await different.run()
        #expect(different.summary == L10n.t("hash.different"))
    }

    @Test func aPastedDigestIsCompared() async throws {
        let (dir, urls) = try files(["abc", "other"])
        defer { FaultFixture.remove(dir) }
        let model = FileHashModel(files: urls)
        await model.run()
        model.expected = abcSHA256.uppercased() + "\n"
        #expect(model.matches(urls[0]) == true)
        #expect(model.matches(urls[1]) == false)
        #expect(model.summary == L10n.f("hash.matches", 1))
        model.expected = String(repeating: "0", count: 64)
        #expect(model.summary == L10n.t("hash.noMatch"))
    }

    @Test func aDigestOfAnAlgorithmThatIsOffSaysSo() async throws {
        let (dir, urls) = try files(["abc"])
        defer { FaultFixture.remove(dir) }
        let model = FileHashModel(files: urls)
        await model.run()
        model.expected = String(repeating: "a", count: 32)
        #expect(model.summary == L10n.f("hash.turnOn", "MD5"))
    }

    @Test func aFailedFileKeepsItsMessageAndIsLeftOutOfTheCopy() async throws {
        let (dir, urls) = try files(["abc"])
        defer { FaultFixture.remove(dir) }
        let missing = dir.appendingPathComponent("missing")
        let model = FileHashModel(files: [missing, urls[0]])
        await model.run()
        #expect(!model.text(for: missing, algorithm: .sha256).isEmpty)
        #expect(model.copyText == "\(abcSHA256)  f0")
    }

    @Test func cancellingKeepsFinishedRowsAndSaysSo() async throws {
        let (dir, urls) = try files(Array(repeating: String(repeating: "x", count: 4 << 20), count: 30))
        defer { FaultFixture.remove(dir) }
        let model = FileHashModel(files: urls)
        for algorithm in HashAlgorithm.allCases { model.set(algorithm, enabled: true) }
        let task = Task { await model.run() }
        model.onChange = { if model.fraction > 0 { task.cancel() } }
        await task.value
        #expect(!model.isRunning)
        #expect(model.wasCancelled)
        #expect(model.summary == L10n.t("hash.cancelled"))
    }

    @Test func noAlgorithmDoesNothing() async throws {
        let (dir, urls) = try files(["abc"])
        defer { FaultFixture.remove(dir) }
        let model = FileHashModel(files: urls)
        model.set(.sha256, enabled: false)
        await model.run()
        #expect(model.rows.isEmpty)
        #expect(model.summary == L10n.t("hash.noAlgorithm"))
    }

    @Test func theSheetBuilds() {
        let sheet = FileHashSheetController(files: [URL(fileURLWithPath: "/a")], host: NSWindow())
        #expect(sheet.model.files.count == 1)
    }
}
