import Testing
import Foundation
import Transfer
import HSpaceContracts
import HSpaceTestSupport

/// H7: a folder that crosses a volume is the same folder afterwards.
@Suite struct TransferFolderMetadataTests {
    static let tagAttribute = "com.apple.metadata:_kMDItemUserTags"
    static let created = Date(timeIntervalSince1970: 1_000_000_000)
    static let modified = Date(timeIntervalSince1970: 1_100_000_000)

    /// Sets everything the folder must keep. Call last: adding children changes the modification date.
    static func dress(_ folder: URL, mode: Int16) throws {
        let tags = Data("bplist-tag".utf8)
        let status = tags.withUnsafeBytes {
            setxattr(folder.path, tagAttribute, $0.baseAddress, tags.count, 0, 0)
        }
        #expect(status == 0)
        try FileManager.default.setAttributes(
            [.creationDate: created, .modificationDate: modified, .posixPermissions: mode], ofItemAtPath: folder.path)
    }

    static func hasTag(_ folder: URL) -> Bool {
        getxattr(folder.path, tagAttribute, nil, 0, 0, 0) > 0
    }

    static func attributes(_ url: URL) throws -> [FileAttributeKey: Any] {
        try FileManager.default.attributesOfItem(atPath: url.path)
    }

    @Test func crossVolumeMoveKeepsFolderDatesTagsAndMode() async throws {
        let volume = try ScratchVolume()
        let base = try FaultFixture.tempDir()
        defer { FaultFixture.remove(base) }
        let source = base.appendingPathComponent("d")
        let nested = source.appendingPathComponent("inner")
        try FaultFixture.write(to: nested.appendingPathComponent("f.txt"))
        try Self.dress(nested, mode: 0o700)
        try Self.dress(source, mode: 0o750)

        try await TransferSafetyTests.run(.move, [source], to: volume.url)

        #expect(!FileManager.default.fileExists(atPath: source.path))
        for (folder, mode) in [(volume.url.appendingPathComponent("d"), 0o750),
                               (volume.url.appendingPathComponent("d/inner"), 0o700)] {
            let kept = try Self.attributes(folder)
            #expect(kept[.modificationDate] as? Date == Self.modified)
            #expect(kept[.creationDate] as? Date == Self.created)
            #expect((kept[.posixPermissions] as? NSNumber)?.intValue == mode)
            #expect(Self.hasTag(folder))
        }
    }

    @Test func aReadOnlyFolderIsFilledBeforeItBecomesReadOnly() async throws {
        let volume = try ScratchVolume()
        let base = try FaultFixture.tempDir()
        defer {
            chmod(volume.url.appendingPathComponent("d").path, 0o755)
            FaultFixture.remove(base)
        }
        let source = base.appendingPathComponent("d")
        try FaultFixture.write(to: source.appendingPathComponent("f.txt"))
        try Self.dress(source, mode: 0o555)

        try await TransferSafetyTests.run(.copy, [source], to: volume.url)

        let copy = volume.url.appendingPathComponent("d")
        #expect(FileManager.default.fileExists(atPath: copy.appendingPathComponent("f.txt").path))
        #expect((try Self.attributes(copy)[.posixPermissions] as? NSNumber)?.intValue == 0o555)
    }

    @Test func aMergeLeavesTheExistingFolderAsItWas() async throws {
        let base = try FaultFixture.tempDir()
        defer { FaultFixture.remove(base) }
        let source = base.appendingPathComponent("src/d")
        let target = base.appendingPathComponent("dst/d")
        try FaultFixture.write(to: source.appendingPathComponent("new.txt"))
        try FaultFixture.write(to: target.appendingPathComponent("old.txt"))
        try Self.dress(source, mode: 0o700)
        try FileManager.default.setAttributes([.posixPermissions: Int16(0o755)], ofItemAtPath: target.path)

        try await TransferSafetyTests.run(.copy, [source], to: target.deletingLastPathComponent(),
                                          TransferSafetyTests.context(.mergeFolders))

        #expect((try Self.attributes(target)[.posixPermissions] as? NSNumber)?.intValue == 0o755)
        #expect(!Self.hasTag(target))
    }
}

/// H7: what a crash left behind. It may be the only copy of an item, so it goes to the Trash rather than away.
@Suite struct TransferLeftoverTests {
    static func leftover(_ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FaultFixture.write(Data("left".utf8), to: url)
        return url
    }

    static func transferOne(into dir: URL) async throws {
        let base = try FaultFixture.tempDir()
        defer { FaultFixture.remove(base) }
        let source = base.appendingPathComponent("incoming.txt")
        try FaultFixture.write(to: source)
        try await TransferSafetyTests.run(.copy, [source], to: dir)
    }

    @Test func leftoversOfADeadProcessGoToTheTrash() async throws {
        let volume = try ScratchVolume()
        // No process can have this id: macOS caps them at 99998
        let dead = try Self.leftover(".hspace-transfer-p99999999-AAAA", in: volume.url)
        let older = try Self.leftover(".hspace-transfer-4F2C8B1E-0000-4000-8000-000000000000", in: volume.url)

        try await Self.transferOne(into: volume.url)

        #expect(!FileManager.default.fileExists(atPath: dead.path))
        #expect(!FileManager.default.fileExists(atPath: older.path))
        #expect(FileManager.default.fileExists(atPath: volume.url.appendingPathComponent("incoming.txt").path))
        let trash = volume.url.appendingPathComponent(".Trashes/\(getuid())")
        let trashed = try FileManager.default.contentsOfDirectory(atPath: trash.path)
        #expect(trashed.filter { $0.hasPrefix(".hspace-transfer-") }.count == 2, "\(trashed)")
    }

    @Test func aRunningProcessKeepsItsStagingItems() async throws {
        let dir = try FaultFixture.tempDir()
        defer { FaultFixture.remove(dir) }
        let live = try Self.leftover(".hspace-transfer-p\(getpid())-AAAA", in: dir)
        try await Self.transferOne(into: dir)
        #expect(FileManager.default.fileExists(atPath: live.path))
    }

    @Test func aSimilarNameIsLeftAlone() async throws {
        let dir = try FaultFixture.tempDir()
        defer { FaultFixture.remove(dir) }
        let other = try Self.leftover(".hspace-transferred", in: dir)
        try await Self.transferOne(into: dir)
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    @Test func aFinishedTransferLeavesNoStagingItem() async throws {
        let dir = try FaultFixture.tempDir()
        defer { FaultFixture.remove(dir) }
        try await Self.transferOne(into: dir)
        #expect(try TransferSafetyTests.names(in: dir) == ["incoming.txt"])
    }
}
