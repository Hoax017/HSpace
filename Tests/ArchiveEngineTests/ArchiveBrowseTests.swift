import ArchiveEngine
import Foundation
import HSpaceContracts
import HSpaceTestSupport
import Testing

/// L50, through the Contract: real tar on real archives. Names are hostile on purpose.
@Suite struct ArchiveBrowseTests {
    static func tar(_ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    /// Packs `files` (relative path to contents) into `dir/fixture.<ext>`, with tar picking the format
    static func archive(_ files: [String: String], ext: String, in dir: URL) throws -> URL {
        let source = try FaultFixture.tempDir("hspace-browse-src")
        defer { FaultFixture.remove(source) }
        for (name, body) in files {
            try FaultFixture.write(Data(body.utf8), to: source.appendingPathComponent(name))
        }
        let archive = dir.appendingPathComponent("fixture.\(ext)")
        try tar(["-a", "-cf", archive.path, "-C", source.path, "."])
        return archive
    }

    static func tree(_ node: ArchiveTreeNode, prefix: String = "") -> [String] {
        node.children.flatMap { child -> [String] in
            let path = prefix + child.name
            return [child.isFolder ? path + "/" : path] + tree(child, prefix: path + "/")
        }
    }

    @Test(arguments: ["zip", "tar", "tar.gz", "tar.bz2", "tar.xz"])
    func listsTheContentOfEveryFormat(ext: String) async throws {
        let dir = try FaultFixture.tempDir("hspace-browse")
        defer { FaultFixture.remove(dir) }
        let archive = try Self.archive(["a b.txt": "12345", "d/é.txt": "x", "d/sub/deep.txt": "y"], ext: ext, in: dir)
        let before = try Data(contentsOf: archive)

        let entries = try await ArchiveEngineNode().list(archive)

        #expect(Self.tree(archiveTree(entries)) == ["d/", "d/sub/", "d/sub/deep.txt", "d/é.txt", "a b.txt"])
        let file = try #require(entries.first { $0.path == "a b.txt" })
        #expect(file.size == 5)
        #expect(file.kind == .file)
        let modified = try #require(file.modified)
        #expect(abs(modified.timeIntervalSinceNow) < 2 * 86_400)
        #expect(try Data(contentsOf: archive) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["fixture.\(ext)"])
    }

    @Test func aSingleStreamHasOneItem() async throws {
        let dir = try FaultFixture.tempDir("hspace-browse")
        defer { FaultFixture.remove(dir) }
        let plain = dir.appendingPathComponent("note.txt")
        try FaultFixture.write(Data("note".utf8), to: plain)
        let process = try Process.run(URL(fileURLWithPath: "/usr/bin/gzip"), arguments: [plain.path])
        process.waitUntilExit()
        let archive = dir.appendingPathComponent("note.txt.gz")

        let entries = try await ArchiveEngineNode().list(archive)
        #expect(entries.map(\.path) == ["note.txt"])
        #expect(entries[0].size == nil)

        let out = try FaultFixture.tempDir("hspace-browse-out")
        defer { FaultFixture.remove(out) }
        let landed = try await ArchiveEngineNode().extract(entries, from: archive, into: out)
        #expect(try Data(contentsOf: landed[0]) == Data("note".utf8))
    }

    @Test func listingFailuresReachTheCaller() async throws {
        let dir = try FaultFixture.tempDir("hspace-browse")
        defer { FaultFixture.remove(dir) }
        let damaged = dir.appendingPathComponent("damaged.zip")
        try FaultFixture.write(Data("this is not a zip".utf8), to: damaged)

        await #expect(throws: ArchiveError.self) { try await ArchiveEngineNode().list(damaged) }
        await #expect(throws: ArchiveError.self) {
            try await ArchiveEngineNode().list(dir.appendingPathComponent("missing.zip"))
        }
        await #expect(throws: ArchiveError.self) {
            try await ArchiveEngineNode().list(dir.appendingPathComponent("plain.txt"))
        }
    }

    @Test func unreadableArchiveIsAnError() async throws {
        let dir = try FaultFixture.tempDir("hspace-browse")
        defer { FaultFixture.remove(dir) }
        let archive = try Self.archive(["a.txt": "a"], ext: "tar", in: dir)
        try await FaultFixture.withUnreadable(archive) {
            await #expect(throws: ArchiveError.self) { try await ArchiveEngineNode().list(archive) }
        }
    }

    @Test func cancellingStopsTheListing() async throws {
        let dir = try FaultFixture.tempDir("hspace-browse")
        defer { FaultFixture.remove(dir) }
        let archive = try Self.archive(["a.txt": "a"], ext: "tar.gz", in: dir)
        let task = Task { try await ArchiveEngineNode().list(archive) }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    // MARK: Extracting chosen entries

    @Test func extractsOnlyTheChosenEntries() async throws {
        let dir = try FaultFixture.tempDir("hspace-browse")
        defer { FaultFixture.remove(dir) }
        let archive = try Self.archive(["plain.txt": "top", "sub/plain.txt": "nested", "other.txt": "no",
                                        "sub2/x.txt": "no"], ext: "zip", in: dir)
        let entries = try await ArchiveEngineNode().list(archive)
        let out = try FaultFixture.tempDir("hspace-browse-out")
        defer { FaultFixture.remove(out) }

        let chosen = entries.filter { $0.path == "plain.txt" }
        let landed = try await ArchiveEngineNode().extract(chosen, from: archive, into: out)

        #expect(landed.map(\.lastPathComponent) == ["plain.txt"])
        #expect(try String(contentsOf: landed[0], encoding: .utf8) == "top")
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == ["plain.txt"])
    }

    @Test func aFolderComesWithItsContent() async throws {
        let dir = try FaultFixture.tempDir("hspace-browse")
        defer { FaultFixture.remove(dir) }
        let archive = try Self.archive(["sub/a.txt": "a", "sub/deep/b.txt": "b", "sub2/c.txt": "c"], ext: "tar.gz", in: dir)
        let tree = archiveTree(try await ArchiveEngineNode().list(archive))
        let folder = try #require(tree.children.first { $0.name == "sub" })
        let out = try FaultFixture.tempDir("hspace-browse-out")
        defer { FaultFixture.remove(out) }

        let landed = try await ArchiveEngineNode().extract([folder.entry], from: archive, into: out)

        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == ["sub"])
        #expect(try String(contentsOf: landed[0].appendingPathComponent("deep/b.txt"), encoding: .utf8) == "b")
    }

    /// Each of these is a pattern, an option or an anchor to a tool that does not treat names as plain text
    @Test(arguments: ["star*.txt", "[x].txt", "^caret.txt", "dollar$", "back\\slash.txt", "-rf", "--to-command=x",
                      "que?tion.txt", "new\nline.txt", "*", "é ü.txt"])
    func hostileNamesExtractAsPlainNames(name: String) async throws {
        let dir = try FaultFixture.tempDir("hspace-browse")
        defer { FaultFixture.remove(dir) }
        let archive = try Self.archive([name: "wanted", "bystander.txt": "no"], ext: "tar", in: dir)
        let entries = try await ArchiveEngineNode().list(archive)
        let chosen = try #require(entries.first { $0.path == name })
        let out = try FaultFixture.tempDir("hspace-browse-out")
        defer { FaultFixture.remove(out) }

        let landed = try await ArchiveEngineNode().extract([chosen], from: archive, into: out)

        #expect(try String(contentsOf: landed[0], encoding: .utf8) == "wanted")
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).count == 1)
    }

    @Test func aHostileArchiveNameIsNotAnOption() async throws {
        let dir = try FaultFixture.tempDir("hspace-browse")
        defer { FaultFixture.remove(dir) }
        let archive = try Self.archive(["a.txt": "a"], ext: "tar", in: dir)
        let hostile = dir.appendingPathComponent("-xf.tar")
        try FileManager.default.moveItem(at: archive, to: hostile)

        #expect(try await ArchiveEngineNode().list(hostile).map(\.path) == ["a.txt"])
    }

    @Test func unsafePathsAreListedButNeverExtracted() async throws {
        let listing = """
        -rw-r--r--  0 a b c  g h         4 Jan  1  1970 ../evil.txt
        -rw-r--r--  0 a b c  g h         4 Jan  1  1970 sub/../../evil.txt
        -rw-r--r--  0 a b c  g h         4 Jan  1  1970 /abs.txt
        -rw-r--r--  0 a b c  g h         4 Jan  1  1970 fine..name.txt
        """
        let entries = try parseArchiveListing(Data(listing.utf8))
        #expect(entries.map(\.isSafe) == [false, false, false, true])
        #expect(archiveTree(entries).children.count == 4)

        let dir = try FaultFixture.tempDir("hspace-browse")
        defer { FaultFixture.remove(dir) }
        let archive = try Self.archive(["a.txt": "a"], ext: "tar", in: dir)
        await #expect(throws: ArchiveError.self) {
            try await ArchiveEngineNode().extract(Array(entries.prefix(1)), from: archive, into: dir)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["fixture.tar"])
    }

    @Test func aMissingEntryIsAnError() async throws {
        let dir = try FaultFixture.tempDir("hspace-browse")
        defer { FaultFixture.remove(dir) }
        let first = try Self.archive(["only.txt": "a"], ext: "tar", in: dir)
        let entries = try await ArchiveEngineNode().list(first)
        let second = dir.appendingPathComponent("other.tar")
        let source = try FaultFixture.tempDir("hspace-browse-src")
        defer { FaultFixture.remove(source) }
        try FaultFixture.write(Data("b".utf8), to: source.appendingPathComponent("different.txt"))
        try Self.tar(["-cf", second.path, "-C", source.path, "different.txt"])
        let out = try FaultFixture.tempDir("hspace-browse-out")
        defer { FaultFixture.remove(out) }

        await #expect(throws: ArchiveError.self) {
            try await ArchiveEngineNode().extract(entries, from: second, into: out)
        }
    }

    @Test func aReadOnlyDestinationIsAnError() async throws {
        let dir = try FaultFixture.tempDir("hspace-browse")
        defer { FaultFixture.remove(dir) }
        let archive = try Self.archive(["a.txt": "a"], ext: "tar", in: dir)
        let entries = try await ArchiveEngineNode().list(archive)
        let out = try FaultFixture.tempDir("hspace-browse-out")
        defer { FaultFixture.remove(out) }
        try await FaultFixture.withReadOnly(out) {
            await #expect(throws: ArchiveError.self) {
                try await ArchiveEngineNode().extract(entries, from: archive, into: out)
            }
        }
    }

    // MARK: Preview

    @Test func aPreviewOfAFileSwappedForALinkShowsNothing() async throws {
        let dir = try FaultFixture.tempDir("hspace-browse")
        defer { FaultFixture.remove(dir) }
        let plain = try FaultFixture.tempDir("hspace-browse-a")
        defer { FaultFixture.remove(plain) }
        let linked = try FaultFixture.tempDir("hspace-browse-b")
        defer { FaultFixture.remove(linked) }
        try FaultFixture.write(Data("harmless".utf8), to: plain.appendingPathComponent("note.txt"))
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("note.txt"),
                                                   withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        let archive = dir.appendingPathComponent("swap.tar")
        try Self.tar(["-cf", archive.path, "-C", plain.path, "note.txt"])
        try Self.tar(["-rf", archive.path, "-C", linked.path, "note.txt"])
        let out = try FaultFixture.tempDir("hspace-browse-out")
        defer { FaultFixture.remove(out) }
        let file = try #require(try await ArchiveEngineNode().list(archive).first { $0.kind == .file })

        let preview = try await ArchiveEngineNode().extractForPreview([file], from: archive, into: out)

        #expect(preview.isEmpty)
    }

    @Test func aPreviewPastTheLimitIsRefusedBeforeExtracting() async throws {
        let dir = try FaultFixture.tempDir("hspace-browse")
        defer { FaultFixture.remove(dir) }
        let archive = try Self.archive(["a.txt": "12345"], ext: "zip", in: dir)
        let entries = try await ArchiveEngineNode().list(archive)
        let out = try FaultFixture.tempDir("hspace-browse-out")
        defer { FaultFixture.remove(out) }

        await #expect(throws: ArchiveError.self) {
            try await ArchiveEngineNode().extractForPreview(entries, from: archive, into: out, byteLimit: 4)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
        #expect(try await ArchiveEngineNode().extractForPreview(entries, from: archive, into: out, byteLimit: 5).count == 1)
    }

    @Test func aPreviewSkipsWhatIsNotAFile() async throws {
        let listing = """
        drwxr-xr-x  0 0  0  0 Jan  1  2020 folder/
        lrwxr-xr-x  0 0  0  0 Jan  1  2020 link -> /etc/hosts
        -rw-r--r--  0 0  0  1 Jan  1  2020 ../evil.txt
        """
        let dir = try FaultFixture.tempDir("hspace-browse")
        defer { FaultFixture.remove(dir) }
        let archive = try Self.archive(["a.txt": "a"], ext: "tar", in: dir)
        let entries = try parseArchiveListing(Data(listing.utf8))

        #expect(try await ArchiveEngineNode().extractForPreview(entries, from: archive, into: dir).isEmpty)
    }

    // MARK: Scratch folders

    @Test func scratchFoldersArePrivateAndGoAwayEvenWhenReadOnly() throws {
        let scratch = try ArchiveEngineNode.makeScratchDirectory()
        let attributes = try FileManager.default.attributesOfItem(atPath: scratch.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o700)

        let locked = scratch.appendingPathComponent("locked")
        try FaultFixture.write(Data("x".utf8), to: locked.appendingPathComponent("file.txt"))
        chmod(locked.path, 0o500)

        try ArchiveEngineNode.discardScratchDirectory(scratch)
        #expect(!FileManager.default.fileExists(atPath: scratch.path))
        try ArchiveEngineNode.discardScratchDirectory(scratch)    // Already gone is fine
    }

    // MARK: Parsing

    @Test func parsesOwnersWithSpacesAndNamesWithSpaces() throws {
        let line = "-rw-r--r--  0 a b c  g h      4096 Jan  2  2015   two leading spaces.txt\n"
        let entries = try parseArchiveListing(Data(line.utf8))
        #expect(entries.map(\.path) == ["  two leading spaces.txt"])
        #expect(entries[0].size == 4096)
    }

    @Test func parsesLinksAndUndoesEscapes() throws {
        let listing = """
        lrwxr-xr-x  0 0      0           0 Nov  5 09:57 ./d/link -> target
        hrw-r--r--  0 0      0           0 Jan  1  1970 hard link to plain.txt
        crw-r--r--  0 0      0        3,4 Jan  1  1970 device
        -rw-r--r--  0 0      0           1 Jan  1  1970 n\\nl.txt
        -rw-r--r--  0 0      0           1 Jan  1  1970 e\\314\\201.txt
        -rw-r--r--  0 0      0           1 Jan  1  1970 back\\\\slash
        """
        let entries = try parseArchiveListing(Data(listing.utf8))
        #expect(entries.map(\.path) == ["d/link", "hard", "device", "n\nl.txt", "e\u{301}.txt", "back\\slash"])
        #expect(entries.prefix(3).allSatisfy { $0.kind == .link })
    }

    @Test func aDateWithoutAYearIsNeverInTheFuture() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 2, day: 10)))
        let listing = """
        -rw-r--r--  0 0  0  1 Dec 25 10:00 old.txt
        -rw-r--r--  0 0  0  1 Feb  9 10:00 recent.txt
        """
        let entries = try parseArchiveListing(Data(listing.utf8), now: now)
        #expect(calendar.component(.year, from: try #require(entries[0].modified)) == 2025)
        #expect(calendar.component(.year, from: try #require(entries[1].modified)) == 2026)
    }

    @Test func aListingThatCannotBeReadIsRefused() {
        #expect(throws: ArchiveError.self) { try parseArchiveListing(Data("not a listing line\n".utf8)) }
    }

    // MARK: Tree

    @Test func theTreeMakesUpMissingFoldersAndKeepsLastDuplicate() throws {
        let listing = """
        -rw-r--r--  0 0  0  1 Jan  1  2020 a/b/c.txt
        -rw-r--r--  0 0  0  2 Jan  1  2020 ./z.txt
        -rw-r--r--  0 0  0  3 Jan  1  2020 z.txt
        drwxr-xr-x  0 0  0  0 Jan  1  2020 ./
        drwxr-xr-x  0 0  0  0 Jan  1  2020 m/
        """
        let tree = archiveTree(try parseArchiveListing(Data(listing.utf8)))
        #expect(Self.tree(tree) == ["a/", "a/b/", "a/b/c.txt", "m/", "z.txt"])
        #expect(tree.children.first { $0.name == "z.txt" }?.entry.size == 3)
    }

    @Test func anEntryUsedAsAFolderStaysAFolder() throws {
        let listing = """
        -rw-r--r--  0 0  0  1 Jan  1  2020 clash
        -rw-r--r--  0 0  0  1 Jan  1  2020 clash/inner.txt
        -rw-r--r--  0 0  0  1 Jan  1  2020 clash
        """
        let tree = archiveTree(try parseArchiveListing(Data(listing.utf8)))
        #expect(Self.tree(tree) == ["clash/", "clash/inner.txt"])
    }

    @Test func namesAreMadeSafeToShow() throws {
        let listing = """
        -rw-r--r--  0 0  0  1 Jan  1  2020 evil\\342\\200\\256txt.exe
        -rw-r--r--  0 0  0  1 Jan  1  2020 line\\nbreak
        -rw-r--r--  0 0  0  1 Jan  1  2020 legacy\\351.txt
        """
        let names = archiveTree(try parseArchiveListing(Data(listing.utf8))).children.map(\.name)
        #expect(names.allSatisfy { !$0.contains("\u{202E}") && !$0.contains("\n") })
        #expect(names.contains("legacy\u{FFFD}.txt"))
    }

    /// APFS refuses such a name, so this archive can be listed and not extracted, and the user gets told
    @Test func aNameThatIsNotUTF8IsListedAndItsExtractionFailsCleanly() async throws {
        let dir = try FaultFixture.tempDir("hspace-browse")
        defer { FaultFixture.remove(dir) }
        let bytes: [UInt8] = Array("legacy".utf8) + [0xE9] + Array(".txt".utf8)
        // A name in Latin-1, as old archivers wrote: built by hand, because the file system refuses it
        var block = [UInt8](repeating: 0, count: 512)
        block.replaceSubrange(0..<bytes.count, with: bytes)
        block.replaceSubrange(100..<107, with: Array("0000644".utf8))
        block.replaceSubrange(108..<115, with: Array("0000000".utf8))
        block.replaceSubrange(116..<123, with: Array("0000000".utf8))
        block.replaceSubrange(124..<135, with: Array("00000000005".utf8))
        block.replaceSubrange(136..<147, with: Array("00000000000".utf8))
        block[156] = UInt8(ascii: "0")
        block.replaceSubrange(257..<262, with: Array("ustar".utf8))
        block.replaceSubrange(148..<156, with: Array("        ".utf8))
        let sum = block.reduce(0) { $0 + Int($1) }
        block.replaceSubrange(148..<155, with: Array(String(format: "%06o\0", sum).utf8))
        var payload = [UInt8](repeating: 0, count: 512)
        payload.replaceSubrange(0..<5, with: Array("hello".utf8))
        let legacy = dir.appendingPathComponent("legacy.tar")
        try Data(block + payload + [UInt8](repeating: 0, count: 1024)).write(to: legacy)
        let entries = try await ArchiveEngineNode().list(legacy)
        #expect(entries.map(\.path) == ["legacy\u{FFFD}.txt"])
        let out = try FaultFixture.tempDir("hspace-browse-out")
        defer { FaultFixture.remove(out) }
        await #expect(throws: ArchiveError.self) {
            try await ArchiveEngineNode().extract(entries, from: legacy, into: out)
        }
    }
}
