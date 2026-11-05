import ArchiveEngine
import Foundation
import HSpaceContracts
import HSpaceTestSupport
import Testing

/// Builds minimal RAR files byte by byte, holding one stored (uncompressed) file: no RAR software runs here or in CI.
private enum RarFixture {
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB8_8320 : 0) }
        }
        return ~crc
    }

    static func little<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian, Array.init)
    }

    private static func rar4Block(_ head: [UInt8]) -> [UInt8] {
        little(UInt16(truncatingIfNeeded: crc32(head))) + head
    }

    static func rar4(name: String, data: [UInt8], fileFlags: UInt16 = 0x8000, method: UInt8 = 0x30) -> Data {
        var out: [UInt8] = Array("Rar!".utf8) + [0x1A, 0x07, 0x00]
        out += rar4Block([0x73] + little(UInt16(0)) + little(UInt16(13)) + [UInt8](repeating: 0, count: 6))
        let nameBytes = Array(name.utf8)
        var body = little(UInt32(data.count)) + little(UInt32(data.count)) + [3]
        body += little(crc32(data)) + little(UInt32(0x5000_0000)) + [20, method]
        body += little(UInt16(nameBytes.count)) + little(UInt32(0o100644)) + nameBytes
        out += rar4Block([0x74] + little(fileFlags) + little(UInt16(7 + body.count)) + body) + data
        out += rar4Block([0x7B] + little(UInt16(0x4000)) + little(UInt16(7)))
        return Data(out)
    }

    private static func vint(_ value: Int) -> [UInt8] {
        var rest = value
        var out: [UInt8] = []
        repeat {
            let low = UInt8(rest & 0x7F)
            rest >>= 7
            out.append(rest == 0 ? low : low | 0x80)
        } while rest != 0
        return out
    }

    private static func rar5Block(_ payload: [UInt8]) -> [UInt8] {
        let size = vint(payload.count)
        return little(crc32(size + payload)) + size + payload
    }

    static func rar5(name: String, data: [UInt8]) -> Data {
        var out: [UInt8] = Array("Rar!".utf8) + [0x1A, 0x07, 0x01, 0x00]
        out += rar5Block(vint(1) + vint(0) + vint(0))
        let nameBytes = Array(name.utf8)
        var file = vint(2) + vint(2) + vint(data.count)
        file += vint(0x4) + vint(data.count) + vint(0o644) + little(crc32(data)) + vint(0) + vint(1)
        file += vint(nameBytes.count) + nameBytes
        out += rar5Block(file) + data
        out += rar5Block(vint(5) + vint(0) + vint(0))
        return Data(out)
    }
}

/// L52: what the system tar reads, with no dependency. See "Review for L52" in ROADMAP.md.
@Suite struct SevenZipRarTests {
    private func extract(_ archive: URL, into out: URL) async throws -> OperationReceipt {
        try await ArchiveEngineNode().execute(
            OperationSpec(kind: .extract, sources: [archive], archiveOptions: ArchiveOptions(extractInto: out)),
            context: NodeContext(operationID: UUID(), report: { _ in }, resolveConflicts: { _ in [:] }))
    }

    private func sevenZip(_ files: [String: String], in dir: URL) throws -> URL {
        let source = try FaultFixture.tempDir("hspace-7z-src")
        defer { FaultFixture.remove(source) }
        for (name, body) in files {
            try FaultFixture.write(Data(body.utf8), to: source.appendingPathComponent(name))
        }
        let archive = dir.appendingPathComponent("fixture.7z")
        try ArchiveBrowseTests.tar(["--format=7zip", "-cf", archive.path, "-C", source.path, "."])
        return archive
    }

    @Test func detectsAndOffersBothFormats() {
        #expect(ArchiveFormat.detect(URL(fileURLWithPath: "/a/x.7Z")) == .sevenZip)
        #expect(ArchiveFormat.detect(URL(fileURLWithPath: "/a/x.rar")) == .rar)
        #expect(ArchiveEngineNode.isSupportedArchive(URL(fileURLWithPath: "/a/x.7z")))
        #expect(ArchiveEngineNode.isBrowsable(URL(fileURLWithPath: "/a/x.rar")))
        #expect(ArchiveEngineNode.supportedExtensions().contains("rar"))
    }

    @Test func aSevenZipRoundTrip() async throws {
        let dir = try FaultFixture.tempDir("hspace-7z")
        defer { FaultFixture.remove(dir) }
        let archive = try sevenZip(["a.txt": "first", "d/é.txt": "second"], in: dir)
        let out = try FaultFixture.tempDir("hspace-7z-out")
        defer { FaultFixture.remove(out) }

        let entries = try await ArchiveEngineNode().list(archive)
        #expect(Set(entries.filter { $0.kind == .file }.map(\.path)) == ["a.txt", "d/é.txt"])

        let receipt = try await extract(archive, into: out)

        let wrapper = try #require(receipt.createdURLs.first)
        #expect(wrapper.lastPathComponent == "fixture")
        #expect(try String(contentsOf: wrapper.appendingPathComponent("d/é.txt"), encoding: .utf8) == "second")
    }

    @Test func chosenEntriesComeOutOfASevenZip() async throws {
        let dir = try FaultFixture.tempDir("hspace-7z")
        defer { FaultFixture.remove(dir) }
        let archive = try sevenZip(["a.txt": "first", "b.txt": "second"], in: dir)
        let out = try FaultFixture.tempDir("hspace-7z-out")
        defer { FaultFixture.remove(out) }
        let chosen = try await ArchiveEngineNode().list(archive).filter { $0.path == "b.txt" }

        _ = try await ArchiveEngineNode().extract(chosen, from: archive, into: out)

        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == ["b.txt"])
    }

    @Test(arguments: [("rar4", RarFixture.rar4(name: "dir/hello.txt", data: Array("hello".utf8))),
                      ("rar5", RarFixture.rar5(name: "dir/hello.txt", data: Array("hello".utf8)))])
    func aRarIsBrowsedAndExtracted(version: String, bytes: Data) async throws {
        let dir = try FaultFixture.tempDir("hspace-rar")
        defer { FaultFixture.remove(dir) }
        let archive = dir.appendingPathComponent("\(version).rar")
        try bytes.write(to: archive)
        let out = try FaultFixture.tempDir("hspace-rar-out")
        defer { FaultFixture.remove(out) }

        let entries = try await ArchiveEngineNode().list(archive)
        #expect(entries.map(\.path) == ["dir/hello.txt"])
        #expect(entries[0].kind == .file)

        _ = try await extract(archive, into: out)

        #expect(try String(contentsOf: out.appendingPathComponent("dir/hello.txt"), encoding: .utf8) == "hello")
    }

    @Test func aRarNeverLandsOutsideTheTarget() async throws {
        let dir = try FaultFixture.tempDir("hspace-rar")
        defer { FaultFixture.remove(dir) }
        let archive = dir.appendingPathComponent("evil.rar")
        try RarFixture.rar4(name: "../evil.txt", data: Array("x".utf8)).write(to: archive)
        let parent = try FaultFixture.tempDir("hspace-rar-out")
        defer { FaultFixture.remove(parent) }
        let out = parent.appendingPathComponent("target")

        await #expect(throws: ArchiveError.self) { _ = try await extract(archive, into: out) }

        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path) == ["target"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
    }

    @Test func anEncryptedRarIsAnErrorAndLeavesNothing() async throws {
        let dir = try FaultFixture.tempDir("hspace-rar")
        defer { FaultFixture.remove(dir) }
        let archive = dir.appendingPathComponent("locked.rar")
        // The password flag on a compressed file, as WinRAR writes it. The data is noise, as ciphertext would be.
        try RarFixture.rar4(name: "secret.txt", data: Array("noise".utf8), fileFlags: 0x8004, method: 0x33).write(to: archive)
        let out = try FaultFixture.tempDir("hspace-rar-out")
        defer { FaultFixture.remove(out) }

        await #expect(throws: ArchiveError.self) { _ = try await extract(archive, into: out) }

        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
    }

    @Test func aTruncatedArchiveIsAnErrorAndLeavesNothing() async throws {
        let dir = try FaultFixture.tempDir("hspace-rar")
        defer { FaultFixture.remove(dir) }
        let archive = dir.appendingPathComponent("cut.7z")
        let whole = try sevenZip(["a.txt": String(repeating: "x", count: 4096)], in: dir)
        try Data(try Data(contentsOf: whole).prefix(40)).write(to: archive)
        let out = try FaultFixture.tempDir("hspace-rar-out")
        defer { FaultFixture.remove(out) }

        await #expect(throws: ArchiveError.self) { _ = try await extract(archive, into: out) }

        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
    }

    @Test func passwordsAreRefusedFor7zAndRar() async throws {
        let dir = try FaultFixture.tempDir("hspace-rar")
        defer { FaultFixture.remove(dir) }
        let archive = try sevenZip(["a.txt": "a"], in: dir)
        await #expect(throws: ArchiveError.self) {
            try await ArchiveEngineNode().execute(
                OperationSpec(kind: .extract, sources: [archive], archiveOptions: ArchiveOptions(password: "pw")),
                context: NodeContext(operationID: UUID(), report: { _ in }, resolveConflicts: { _ in [:] }))
        }
    }
}
