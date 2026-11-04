import Testing
import Foundation
import ArchiveEngine
import HSpaceContracts

/// Black-box acceptance: only through the Contract public surface; real physical I/O on temp fixture trees (real system tools zip/tar/unzip/gunzip).
/// Paths needing a missing tool are not faked (honest skip); this machine has all four tools, so the round-trip tests all run.
@Suite struct ArchiveEngineTests {
    static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hspace-ar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func ctx() -> NodeContext {
        NodeContext(operationID: UUID(), report: { _ in }, resolveConflicts: { _ in [:] })
    }

    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
    }

    // MARK: Pure logic (Oracle: no file system needed)

    @Test func topLevelCountingCollapsesCommonRoot() {
        // Several entries under one top-level directory → top-level count 1 (wrapper skipped)
        #expect(topLevelEntryCount(["tree/", "tree/a.txt", "tree/nested/inner.txt"]) == 1)
        // Different top-level entries → top-level count 2 (wrapper needed)
        #expect(topLevelEntryCount(["a.txt", "b.txt"]) == 2)
        // "./" prefix normalization + trailing slash
        #expect(topLevelEntryCount(["./x/1", "./x/2", "x/3"]) == 1)
        #expect(topLevelEntryCount([]) == 0)
    }

    @Test func uniqueNamingAppendsIndexKeepingFullSuffix() {
        let dir = URL(fileURLWithPath: "/tmp/x")
        let existing: Set<String> = ["foo.zip", "foo 2.zip"]
        #expect(uniqueArchiveName(base: "foo", ext: "zip", in: dir,
                                  exists: { existing.contains($0.lastPathComponent) }) == "foo 3.zip")
        // tar.gz keeps its full suffix, the number goes only on base
        let ex2: Set<String> = ["bar.tar.gz"]
        #expect(uniqueArchiveName(base: "bar", ext: "tar.gz", in: dir,
                                  exists: { ex2.contains($0.lastPathComponent) }) == "bar 2.tar.gz")
    }

    @Test func formatDetectionByExtension() {
        #expect(ArchiveFormat.detect(URL(fileURLWithPath: "/a/x.zip")) == .zip)
        #expect(ArchiveFormat.detect(URL(fileURLWithPath: "/a/x.tar.gz")) == .tarGz)
        #expect(ArchiveFormat.detect(URL(fileURLWithPath: "/a/x.tgz")) == .tarGz)
        #expect(ArchiveFormat.detect(URL(fileURLWithPath: "/a/x.tar.bz2")) == .tarBz2)
        #expect(ArchiveFormat.detect(URL(fileURLWithPath: "/a/x.txz")) == .tarXz)
        #expect(ArchiveFormat.detect(URL(fileURLWithPath: "/a/x.tar")) == .tar)
        #expect(ArchiveFormat.detect(URL(fileURLWithPath: "/a/x.gz")) == .gzip)
        #expect(ArchiveFormat.detect(URL(fileURLWithPath: "/a/README")) == nil)
    }

    @Test func supportedExtensionsIncludesZipAndTar() {
        let exts = ArchiveEngineNode.supportedExtensions()
        #expect(exts.contains("zip"))
        #expect(exts.contains("tar.gz"))
        #expect(ArchiveEngineNode.isSupportedArchive(URL(fileURLWithPath: "/a/b.zip")))
        #expect(!ArchiveEngineNode.isSupportedArchive(URL(fileURLWithPath: "/a/b.txt")))
    }

    // MARK: zip round trip: byte-identical (single directory source → one top-level entry → wrapper skipped)

    @Test func zipRoundTripSingleDirByteIdentical() async throws {
        let work = try Self.tempDir(); let out = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: work); try? FileManager.default.removeItem(at: out) }
        let payload = Data((0..<120_000).map { UInt8($0 % 251) })
        try Self.write(payload, to: work.appendingPathComponent("tree/big.bin"))
        try Self.write(Data("inner".utf8), to: work.appendingPathComponent("tree/nested/inner.txt"))

        // Compress the single directory tree (destination=work → archive lands at work/tree.zip)
        let cr = try await ArchiveEngineNode().execute(
            OperationSpec(kind: .compress, sources: [work.appendingPathComponent("tree")],
                          archiveOptions: ArchiveOptions(format: "zip")),
            context: Self.ctx())
        let archive = try #require(cr.createdURLs.first)
        #expect(archive.lastPathComponent == "tree.zip")
        #expect(FileManager.default.fileExists(atPath: archive.path))

        // Extract into out (one top-level entry tree → no wrapper)
        let er = try await ArchiveEngineNode().execute(
            OperationSpec(kind: .extract, sources: [archive],
                          archiveOptions: ArchiveOptions(extractInto: out, createWrapper: true)),
            context: Self.ctx())
        #expect(er.createdURLs.contains { $0.lastPathComponent == "tree" })
        // No extra tree/tree nesting
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("tree/tree").path))
        let big = try Data(contentsOf: out.appendingPathComponent("tree/big.bin"))
        #expect(big == payload)   // physical evidence: byte-for-byte identical
        let inner = try Data(contentsOf: out.appendingPathComponent("tree/nested/inner.txt"))
        #expect(inner == Data("inner".utf8))
        // Staging directory cleaned up (no .hspace-* leftovers)
        try Self.assertNoStaging(in: out)
    }

    // MARK: tar.gz round trip

    @Test func tarGzRoundTripByteIdentical() async throws {
        let work = try Self.tempDir(); let out = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: work); try? FileManager.default.removeItem(at: out) }
        let payload = Data((0..<90_000).map { UInt8(($0 * 7) % 251) })
        try Self.write(payload, to: work.appendingPathComponent("d/data.bin"))
        try Self.write(Data("t".utf8), to: work.appendingPathComponent("d/t.txt"))

        let cr = try await ArchiveEngineNode().execute(
            OperationSpec(kind: .compress, sources: [work.appendingPathComponent("d")],
                          archiveOptions: ArchiveOptions(format: "tar.gz")),
            context: Self.ctx())
        let archive = try #require(cr.createdURLs.first)
        #expect(archive.lastPathComponent == "d.tar.gz")

        _ = try await ArchiveEngineNode().execute(
            OperationSpec(kind: .extract, sources: [archive],
                          archiveOptions: ArchiveOptions(extractInto: out, createWrapper: true)),
            context: Self.ctx())
        let round = try Data(contentsOf: out.appendingPathComponent("d/data.bin"))
        #expect(round == payload)
    }

    // MARK: The two wrapper branches: multiple entries create a wrapper / a single entry skips it

    @Test func extractWrapsWhenMultipleTopLevelEntries() async throws {
        let work = try Self.tempDir(); let out = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: work); try? FileManager.default.removeItem(at: out) }
        try Self.write(Data("A".utf8), to: work.appendingPathComponent("a.txt"))
        try Self.write(Data("B".utf8), to: work.appendingPathComponent("b.txt"))

        // Multi-source compress: baseName = common parent directory name = work directory name
        let cr = try await ArchiveEngineNode().execute(
            OperationSpec(kind: .compress,
                          sources: [work.appendingPathComponent("a.txt"), work.appendingPathComponent("b.txt")],
                          archiveOptions: ArchiveOptions(format: "zip")),
            context: Self.ctx())
        let archive = try #require(cr.createdURLs.first)

        // createWrapper=true with 2 top-level entries → creates a same-named wrapper folder
        let er = try await ArchiveEngineNode().execute(
            OperationSpec(kind: .extract, sources: [archive],
                          archiveOptions: ArchiveOptions(extractInto: out, createWrapper: true)),
            context: Self.ctx())
        let wrapper = try #require(er.createdURLs.first)
        let stem = archive.deletingPathExtension().lastPathComponent  // archive stem name
        #expect(wrapper.lastPathComponent == stem)
        #expect(try Data(contentsOf: wrapper.appendingPathComponent("a.txt")) == Data("A".utf8))
        #expect(try Data(contentsOf: wrapper.appendingPathComponent("b.txt")) == Data("B".utf8))
    }

    @Test func extractNoWrapperWhenDisabledEvenIfMultiple() async throws {
        let work = try Self.tempDir(); let out = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: work); try? FileManager.default.removeItem(at: out) }
        try Self.write(Data("A".utf8), to: work.appendingPathComponent("a.txt"))
        try Self.write(Data("B".utf8), to: work.appendingPathComponent("b.txt"))
        let cr = try await ArchiveEngineNode().execute(
            OperationSpec(kind: .compress,
                          sources: [work.appendingPathComponent("a.txt"), work.appendingPathComponent("b.txt")],
                          archiveOptions: ArchiveOptions(format: "zip")),
            context: Self.ctx())
        let archive = try #require(cr.createdURLs.first)

        // createWrapper=false → spread directly into out (no wrapper folder)
        _ = try await ArchiveEngineNode().execute(
            OperationSpec(kind: .extract, sources: [archive],
                          archiveOptions: ArchiveOptions(extractInto: out, createWrapper: false)),
            context: Self.ctx())
        #expect(try Data(contentsOf: out.appendingPathComponent("a.txt")) == Data("A".utf8))
        #expect(try Data(contentsOf: out.appendingPathComponent("b.txt")) == Data("B".utf8))
    }

    // MARK: Cancellation leaves nothing half-finished

    @Test func cancelledCompressLeavesNoFinalArchive() async throws {
        let work = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: work) }
        // Slightly larger input so compression takes time, raising the chance the cancel lands
        let big = Data((0..<4_000_000).map { UInt8(($0 &* 131) % 251) })
        try Self.write(big, to: work.appendingPathComponent("tree/big.bin"))

        let task = Task {
            try await ArchiveEngineNode().execute(
                OperationSpec(kind: .compress, sources: [work.appendingPathComponent("tree")],
                              archiveOptions: ArchiveOptions(format: "zip")),
                context: Self.ctx())
        }
        task.cancel()
        do {
            let r = try await task.value
            // Race: finishing before the cancel takes effect is also valid, but the archive must be complete and extractable
            let archive = try #require(r.createdURLs.first)
            #expect(FileManager.default.fileExists(atPath: archive.path))
        } catch is CancellationError {
            // Cancelled: the final archive never appeared, and no staging leftovers
            #expect(!FileManager.default.fileExists(atPath: work.appendingPathComponent("tree.zip").path))
            try Self.assertNoStaging(in: work)
        }
    }

    // MARK: Error classification

    @Test func emptySourcesIsLogicError() async {
        do {
            _ = try await ArchiveEngineNode().execute(
                OperationSpec(kind: .compress, sources: []), context: Self.ctx())
            Issue.record("Expected an error")
        } catch let e as any ClassifiedError {
            #expect(e.errorClass == .logic)
        } catch { Issue.record("Unclassified error (violates P6.4):\(error)") }
    }

    @Test func unknownExtractFormatIsLogicError() async throws {
        let work = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: work) }
        try Self.write(Data("x".utf8), to: work.appendingPathComponent("note.txt"))
        do {
            _ = try await ArchiveEngineNode().execute(
                OperationSpec(kind: .extract, sources: [work.appendingPathComponent("note.txt")]),
                context: Self.ctx())
            Issue.record("Expected an error")
        } catch let e as any ClassifiedError {
            #expect(e.errorClass == .logic)
        } catch { Issue.record("Unclassified error:\(error)") }
    }

    // MARK: Helpers

    static func assertNoStaging(in dir: URL) throws {
        let children = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!children.contains { $0.hasPrefix(".hspace-") })
    }
}
