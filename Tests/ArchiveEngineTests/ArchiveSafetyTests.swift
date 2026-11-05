import Testing
import Foundation
import ArchiveEngine
import HSpaceContracts
import HSpaceTestSupport

/// Safety baseline for track B: real system tools and real file system, through the Contract only.
@Suite struct ArchiveSafetyTests {

    /// Answers the conflict panel with a fixed decision and records what it was shown.
    final class Arbiter: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [FileConflict] = []
        private let answer: ConflictDecision?
        private let cancels: Bool

        init(answer: ConflictDecision?, cancels: Bool = false) {
            self.answer = answer
            self.cancels = cancels
        }

        var conflicts: [FileConflict] { lock.withLock { seen } }

        var context: NodeContext {
            NodeContext(operationID: UUID(), report: { _ in }, resolveConflicts: { [self] conflicts in
                lock.withLock { seen += conflicts }
                if cancels { return nil }
                guard let answer else { return [:] }
                return Dictionary(uniqueKeysWithValues: conflicts.map { ($0.source, answer) })
            })
        }
    }

    static func read(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    static func entries(_ dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    static func tool(_ path: String, _ args: [String], cwd: URL? = nil) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.currentDirectoryURL = cwd
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }

    /// Writes `files` (relative path to contents) to a scratch folder and zips them into `<dir>/fixture.zip`.
    static func zipFixture(_ files: [String: String], in dir: URL) throws -> URL {
        let src = try FaultFixture.tempDir("hspace-ar-src")
        defer { FaultFixture.remove(src) }
        for (name, body) in files {
            try FaultFixture.write(Data(body.utf8), to: src.appendingPathComponent(name))
        }
        let archive = dir.appendingPathComponent("fixture.zip")
        try tool("/usr/bin/zip", ["-r", "-q", archive.path, "."], cwd: src)
        return archive
    }

    static func extract(_ archive: URL, into out: URL, wrapper: Bool = false,
                        context: NodeContext) async throws -> OperationReceipt {
        try await ArchiveEngineNode().execute(
            OperationSpec(kind: .extract, sources: [archive],
                          archiveOptions: ArchiveOptions(extractInto: out, createWrapper: wrapper)),
            context: context)
    }

    /// Compresses `names` from `work`, extracts into `out`, and returns what landed there by name.
    static func roundTrip(_ names: [String], format: String, in work: URL, out: URL) async throws -> [String: String] {
        for name in names {
            try FaultFixture.write(Data("body of \(name)".utf8), to: work.appendingPathComponent(name))
        }
        let receipt = try await ArchiveEngineNode().execute(
            OperationSpec(kind: .compress, sources: names.map { work.appendingPathComponent($0) },
                          newName: "bundle", archiveOptions: ArchiveOptions(format: format)),
            context: Arbiter(answer: nil).context)
        let archive = try #require(receipt.createdURLs.first)
        _ = try await extract(archive, into: out, context: Arbiter(answer: nil).context)
        var found: [String: String] = [:]
        for name in try entries(out) {
            found[name] = try read(out.appendingPathComponent(name))
        }
        return found
    }

    static func assertNoStaging(in dir: URL) throws {
        #expect(!(try entries(dir)).contains { $0.hasPrefix(".hspace-") })
    }

    static func expectClassified(_ body: () async throws -> Void) async {
        do {
            try await body()
            Issue.record("Expected an error")
        } catch is any ClassifiedError {
        } catch {
            Issue.record("Unclassified error: \(error)")
        }
    }

    // MARK: B1 extraction never deletes an existing item without a decision

    @Test func collisionWithoutDecisionKeepsBoth() async throws {
        let work = try FaultFixture.tempDir(); let out = try FaultFixture.tempDir()
        defer { FaultFixture.remove(work); FaultFixture.remove(out) }
        let archive = try Self.zipFixture(["a.txt": "new"], in: work)
        try FaultFixture.write(Data("old".utf8), to: out.appendingPathComponent("a.txt"))

        let arbiter = Arbiter(answer: nil)   // the kernel answers [:] when no panel is attached
        let receipt = try await Self.extract(archive, into: out, context: arbiter.context)

        #expect(try Self.read(out.appendingPathComponent("a.txt")) == "old")
        #expect(try Self.read(out.appendingPathComponent("a 2.txt")) == "new")
        #expect(receipt.createdURLs.map(\.lastPathComponent) == ["a 2.txt"])
        #expect(try Self.entries(out) == ["a 2.txt", "a.txt"])
    }

    @Test func collisionAsksThePanelAboutTheRealItem() async throws {
        let work = try FaultFixture.tempDir(); let out = try FaultFixture.tempDir()
        defer { FaultFixture.remove(work); FaultFixture.remove(out) }
        let archive = try Self.zipFixture(["a.txt": "new", "tree/x": "new"], in: work)
        try FaultFixture.write(Data("old".utf8), to: out.appendingPathComponent("a.txt"))
        try FaultFixture.write(Data("old".utf8), to: out.appendingPathComponent("tree/y"))

        let arbiter = Arbiter(answer: .keepBoth)
        _ = try await Self.extract(archive, into: out, context: arbiter.context)

        let byName = Dictionary(uniqueKeysWithValues: arbiter.conflicts.map { ($0.existing.lastPathComponent, $0) })
        #expect(byName.count == 2)
        #expect(byName["a.txt"]?.existing == out.appendingPathComponent("a.txt"))
        #expect(byName["a.txt"]?.bothDirectories == false)
        #expect(byName["tree"]?.bothDirectories == true)
    }

    @Test func singleStreamCollisionKeepsBoth() async throws {
        let out = try FaultFixture.tempDir()
        defer { FaultFixture.remove(out) }
        let plain = out.appendingPathComponent("notes.txt")
        try FaultFixture.write(Data("new".utf8), to: plain)
        try Self.tool("/usr/bin/gzip", [plain.path])
        try FaultFixture.write(Data("old".utf8), to: plain)

        _ = try await ArchiveEngineNode().execute(
            OperationSpec(kind: .extract, sources: [out.appendingPathComponent("notes.txt.gz")]),
            context: Arbiter(answer: nil).context)

        #expect(try Self.read(plain) == "old")
        #expect(try Self.read(out.appendingPathComponent("notes 2.txt")) == "new")
    }

    @Test func danglingLinkCountsAsACollision() async throws {
        let work = try FaultFixture.tempDir(); let out = try FaultFixture.tempDir()
        defer { FaultFixture.remove(work); FaultFixture.remove(out) }
        let archive = try Self.zipFixture(["a.txt": "new"], in: work)
        let link = try FaultFixture.danglingLink(at: out.appendingPathComponent("a.txt"))
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)

        let arbiter = Arbiter(answer: nil)
        _ = try await Self.extract(archive, into: out, context: arbiter.context)

        #expect(arbiter.conflicts.count == 1)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target)
        #expect(try Self.read(out.appendingPathComponent("a 2.txt")) == "new")
    }

    @Test func replaceDecisionReplaces() async throws {
        let work = try FaultFixture.tempDir(); let out = try FaultFixture.tempDir()
        defer { FaultFixture.remove(work); FaultFixture.remove(out) }
        let archive = try Self.zipFixture(["tree/new": "new"], in: work)
        try FaultFixture.write(Data("old".utf8), to: out.appendingPathComponent("tree/old"))

        _ = try await Self.extract(archive, into: out, context: Arbiter(answer: .replace).context)

        #expect(try Self.entries(out.appendingPathComponent("tree")) == ["new"])
        #expect(try Self.entries(out) == ["tree"])
    }

    @Test func failedReplaceKeepsTheOldItem() async throws {
        let work = try FaultFixture.tempDir(); let out = try FaultFixture.tempDir()
        defer { FaultFixture.remove(work); FaultFixture.remove(out) }
        let archive = try Self.zipFixture(["tree/new": "new"], in: work)
        let old = out.appendingPathComponent("tree")
        try FaultFixture.write(Data("old".utf8), to: old.appendingPathComponent("old"))

        // A read-only folder cannot be reparented, so the replace fails at its first step.
        await Self.expectClassified {
            try await FaultFixture.withReadOnly(old) {
                _ = try await Self.extract(archive, into: out, context: Arbiter(answer: .replace).context)
            }
        }

        #expect(try Self.read(old.appendingPathComponent("old")) == "old")
        #expect(try Self.entries(out) == ["tree"])
    }

    @Test func skipDecisionLeavesTheExistingItem() async throws {
        let work = try FaultFixture.tempDir(); let out = try FaultFixture.tempDir()
        defer { FaultFixture.remove(work); FaultFixture.remove(out) }
        let archive = try Self.zipFixture(["a.txt": "new", "b.txt": "new"], in: work)
        try FaultFixture.write(Data("old".utf8), to: out.appendingPathComponent("a.txt"))

        let receipt = try await Self.extract(archive, into: out, context: Arbiter(answer: .skip).context)

        #expect(try Self.read(out.appendingPathComponent("a.txt")) == "old")
        #expect(try Self.read(out.appendingPathComponent("b.txt")) == "new")
        #expect(receipt.createdURLs.map(\.lastPathComponent) == ["b.txt"])
        #expect(try Self.entries(out) == ["a.txt", "b.txt"])
    }

    @Test func renameDecisionNeverLandsOnAnExistingName() async throws {
        let work = try FaultFixture.tempDir(); let out = try FaultFixture.tempDir()
        defer { FaultFixture.remove(work); FaultFixture.remove(out) }
        let archive = try Self.zipFixture(["a.txt": "new"], in: work)
        try FaultFixture.write(Data("old".utf8), to: out.appendingPathComponent("a.txt"))
        try FaultFixture.write(Data("taken".utf8), to: out.appendingPathComponent("b.txt"))

        _ = try await Self.extract(archive, into: out, context: Arbiter(answer: .rename("../b.txt")).context)

        #expect(try Self.read(out.appendingPathComponent("a.txt")) == "old")
        #expect(try Self.read(out.appendingPathComponent("b.txt")) == "taken")
        #expect(try Self.read(out.appendingPathComponent("b 2.txt")) == "new")
    }

    @Test func cancelInThePanelChangesNothing() async throws {
        let work = try FaultFixture.tempDir(); let out = try FaultFixture.tempDir()
        defer { FaultFixture.remove(work); FaultFixture.remove(out) }
        let archive = try Self.zipFixture(["a.txt": "new", "b.txt": "new"], in: work)
        try FaultFixture.write(Data("old".utf8), to: out.appendingPathComponent("a.txt"))

        await #expect(throws: CancellationError.self) {
            _ = try await Self.extract(archive, into: out,
                                       context: Arbiter(answer: nil, cancels: true).context)
        }

        #expect(try Self.read(out.appendingPathComponent("a.txt")) == "old")
        #expect(try Self.entries(out) == ["a.txt"])
    }

    @Test func mergeKeepsOtherItemsAndReplacesFileOverFileOnly() async throws {
        let work = try FaultFixture.tempDir(); let out = try FaultFixture.tempDir()
        defer { FaultFixture.remove(work); FaultFixture.remove(out) }
        let archive = try Self.zipFixture(["tree/same.txt": "new", "tree/added.txt": "new",
                                           "tree/sub/in.txt": "new", "tree/kind": "new file"], in: work)
        let tree = out.appendingPathComponent("tree")
        try FaultFixture.write(Data("old".utf8), to: tree.appendingPathComponent("same.txt"))
        try FaultFixture.write(Data("old".utf8), to: tree.appendingPathComponent("mine.txt"))
        try FaultFixture.write(Data("old".utf8), to: tree.appendingPathComponent("sub/mine.txt"))
        try FaultFixture.write(Data("old".utf8), to: tree.appendingPathComponent("kind/keep.txt"))

        _ = try await Self.extract(archive, into: out, context: Arbiter(answer: .mergeFolders).context)

        #expect(try Self.read(tree.appendingPathComponent("same.txt")) == "new")
        #expect(try Self.read(tree.appendingPathComponent("added.txt")) == "new")
        #expect(try Self.read(tree.appendingPathComponent("mine.txt")) == "old")
        #expect(try Self.read(tree.appendingPathComponent("sub/in.txt")) == "new")
        #expect(try Self.read(tree.appendingPathComponent("sub/mine.txt")) == "old")
        // A file never takes the place of a folder: both stay.
        #expect(try Self.read(tree.appendingPathComponent("kind/keep.txt")) == "old")
        #expect(try Self.read(tree.appendingPathComponent("kind 2")) == "new file")
        #expect(try Self.entries(out) == ["tree"])
    }

    @Test func mergeIsNotApplicableToAFile() async throws {
        let work = try FaultFixture.tempDir(); let out = try FaultFixture.tempDir()
        defer { FaultFixture.remove(work); FaultFixture.remove(out) }
        let archive = try Self.zipFixture(["a.txt": "new"], in: work)
        try FaultFixture.write(Data("old".utf8), to: out.appendingPathComponent("a.txt"))

        _ = try await Self.extract(archive, into: out, context: Arbiter(answer: .mergeFolders).context)

        #expect(try Self.read(out.appendingPathComponent("a.txt")) == "old")
        #expect(try Self.read(out.appendingPathComponent("a 2.txt")) == "new")
    }

    @Test func unwritableTargetReportsAClassifiedError() async throws {
        let work = try FaultFixture.tempDir(); let out = try FaultFixture.tempDir()
        defer { FaultFixture.remove(work); FaultFixture.remove(out) }
        let archive = try Self.zipFixture(["a.txt": "new"], in: work)
        try FaultFixture.write(Data("old".utf8), to: out.appendingPathComponent("a.txt"))

        await Self.expectClassified {
            try await FaultFixture.withReadOnly(out) {
                _ = try await Self.extract(archive, into: out, context: Arbiter(answer: .replace).context)
            }
        }
        #expect(try Self.read(out.appendingPathComponent("a.txt")) == "old")
    }

    // MARK: B2 a file name is never read as an option

    static let hostileNames = ["-", "-x", "-r", "-Cfoo", "-T", "@bar", "--help", "a.txt"]

    @Test(arguments: ["zip", "tar.gz"])
    func namesThatLookLikeOptionsRoundTrip(format: String) async throws {
        let work = try FaultFixture.tempDir(); let out = try FaultFixture.tempDir()
        defer { FaultFixture.remove(work); FaultFixture.remove(out) }

        let found = try await Self.roundTrip(Self.hostileNames, format: format, in: work, out: out)

        #expect(found == Dictionary(uniqueKeysWithValues: Self.hostileNames.map { ($0, "body of \($0)") }))
    }

    /// `zip -T -TTprogram` runs program on the new archive, and python3 runs a __main__.py found in a zip.
    /// Before B2, selecting these three files and compressing them executed the script.
    @Test func zipTestCommandIsNotReachableThroughFileNames() async throws {
        let work = try FaultFixture.tempDir(); let out = try FaultFixture.tempDir()
        defer { FaultFixture.remove(work); FaultFixture.remove(out) }
        let names = ["-T", "-TTpython3", "__main__.py"]
        for name in names {
            try FaultFixture.write(Data("open('pwned', 'w').close()\n".utf8), to: work.appendingPathComponent(name))
        }

        let receipt = try await ArchiveEngineNode().execute(
            OperationSpec(kind: .compress, sources: names.map { work.appendingPathComponent($0) },
                          newName: "bundle", archiveOptions: ArchiveOptions(format: "zip")),
            context: Arbiter(answer: nil).context)

        #expect(!FileManager.default.fileExists(atPath: work.appendingPathComponent("pwned").path))
        let archive = try #require(receipt.createdURLs.first)
        _ = try await Self.extract(archive, into: out, context: Arbiter(answer: nil).context)
        #expect(try Self.entries(out) == names.sorted())
    }

    // MARK: B3 a tool that writes a lot does not block on a full pipe

    @Test func toolWritingMoreThanAPipeHoldsDoesNotHang() async throws {
        let work = try FaultFixture.tempDir()
        defer { FaultFixture.remove(work) }
        // zip writes a 31-byte warning per unreadable file and carries on, well past the 64 KB a pipe holds
        let tree = work.appendingPathComponent("tree")
        for index in 0..<3000 {
            let file = tree.appendingPathComponent("\(index)")
            try FaultFixture.write(to: file)
            #expect(chmod(file.path, 0) == 0)
        }

        let task = Task {
            try await ArchiveEngineNode().execute(
                OperationSpec(kind: .compress, sources: [tree], archiveOptions: ArchiveOptions(format: "zip")),
                context: Arbiter(answer: nil).context)
        }
        // Stops the blocked tool if the test is about to fail, so a hang cannot hold up the run.
        let watchdog = Task {
            try await Task.sleep(for: .seconds(20))
            task.cancel()
        }
        defer { watchdog.cancel() }

        do {
            _ = try await task.value
            Issue.record("Expected zip to report the unreadable files")
        } catch is CancellationError {
            Issue.record("The tool hung until the watchdog stopped it")
        } catch let error as any ClassifiedError {
            #expect(error.errorClass == .external)
        }
        try Self.assertNoStaging(in: work)
    }

    @Test func archiveNameStartingWithADashExtracts() async throws {
        let work = try FaultFixture.tempDir(); let out = try FaultFixture.tempDir()
        defer { FaultFixture.remove(work); FaultFixture.remove(out) }
        let archive = try Self.zipFixture(["a.txt": "new"], in: work)
        let dashed = work.appendingPathComponent("-x.zip")
        try FileManager.default.moveItem(at: archive, to: dashed)

        _ = try await Self.extract(dashed, into: out, context: Arbiter(answer: nil).context)

        #expect(try Self.read(out.appendingPathComponent("a.txt")) == "new")
    }
}
