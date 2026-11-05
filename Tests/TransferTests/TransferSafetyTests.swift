import Testing
import Foundation
import Transfer
import HSpaceContracts
import HSpaceTestSupport

/// Failure behaviour of the engine (Phase 0, Track A): real OS failures, black box through the Contract.
@Suite struct TransferSafetyTests {
    static func context(_ decision: ConflictDecision? = nil,
                        report: @escaping @Sendable (NodeEvent) -> Void = { _ in }) -> NodeContext {
        NodeContext(operationID: UUID(), report: report, resolveConflicts: { conflicts in
            guard let decision else { return [:] }
            return Dictionary(conflicts.map { ($0.source, decision) }, uniquingKeysWith: { a, _ in a })
        })
    }

    static func run(_ kind: OperationSpec.Kind, _ sources: [URL], to destination: URL?,
                    _ context: NodeContext = context()) async throws {
        _ = try await TransferNode().execute(
            OperationSpec(kind: kind, sources: sources, destination: destination), context: context)
    }

    static func text(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    static func names(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    // MARK: A1 atomic replace

    @Test func failedReplaceKeepsOldFile() async throws {
        let base = try FaultFixture.tempDir()
        defer { FaultFixture.remove(base) }
        let source = base.appendingPathComponent("src/f.txt")
        let target = base.appendingPathComponent("dst/f.txt")
        try FaultFixture.write(Data("new".utf8), to: source)
        try FaultFixture.write(Data("old".utf8), to: target)

        await #expect(throws: (any Error).self) {
            try await FaultFixture.withMode(0o000, on: source) {
                try await Self.run(.copy, [source], to: target.deletingLastPathComponent(), Self.context(.replace))
            }
        }
        #expect(try Self.text(target) == "old")
        #expect(try Self.names(in: target.deletingLastPathComponent()) == ["f.txt"])
    }

    @Test func failedReplaceKeepsOldFolder() async throws {
        let base = try FaultFixture.tempDir()
        defer { FaultFixture.remove(base) }
        let source = base.appendingPathComponent("src/d")
        let target = base.appendingPathComponent("dst/d")
        try FaultFixture.write(Data("a".utf8), to: source.appendingPathComponent("a.txt"))
        let locked = source.appendingPathComponent("z.txt")
        try FaultFixture.write(Data("z".utf8), to: locked)
        try FaultFixture.write(Data("old".utf8), to: target.appendingPathComponent("old.txt"))

        await #expect(throws: (any Error).self) {
            try await FaultFixture.withMode(0o000, on: locked) {
                try await Self.run(.copy, [source], to: target.deletingLastPathComponent(), Self.context(.replace))
            }
        }
        #expect(try Self.names(in: target) == ["old.txt"])
        #expect(try Self.names(in: target.deletingLastPathComponent()) == ["d"])
    }

    @Test func failedSameVolumeMoveReplaceKeepsOldFile() async throws {
        let base = try FaultFixture.tempDir()
        defer { FaultFixture.remove(base) }
        let sourceDir = base.appendingPathComponent("src")
        let source = sourceDir.appendingPathComponent("f.txt")
        let target = base.appendingPathComponent("dst/f.txt")
        try FaultFixture.write(Data("new".utf8), to: source)
        try FaultFixture.write(Data("old".utf8), to: target)

        await #expect(throws: (any Error).self) {
            try await FaultFixture.withReadOnly(sourceDir) {
                try await Self.run(.move, [source], to: target.deletingLastPathComponent(), Self.context(.replace))
            }
        }
        #expect(try Self.text(target) == "old")
        #expect(try Self.text(source) == "new")
    }

    @Test func moveReplaceSwapsAndLeavesNothingBehind() async throws {
        let base = try FaultFixture.tempDir()
        defer { FaultFixture.remove(base) }
        let source = base.appendingPathComponent("src/d")
        let target = base.appendingPathComponent("dst/d")
        try FaultFixture.write(Data("new".utf8), to: source.appendingPathComponent("n.txt"))
        try FaultFixture.write(Data("old".utf8), to: target.appendingPathComponent("o.txt"))

        try await Self.run(.move, [source], to: target.deletingLastPathComponent(), Self.context(.replace))
        #expect(try Self.names(in: target) == ["n.txt"])
        #expect(try Self.names(in: target.deletingLastPathComponent()) == ["d"])
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test func replaceOnFullVolumeKeepsOldFile() async throws {
        let volume = try ScratchVolume()
        let base = try FaultFixture.tempDir()
        defer { FaultFixture.remove(base) }
        let source = base.appendingPathComponent("big.bin")
        let target = volume.url.appendingPathComponent("big.bin")
        try FaultFixture.write(Data("old".utf8), to: target)
        try volume.fill(leaving: 256 * 1024)
        try FaultFixture.write(Data(repeating: 7, count: 2 * 1024 * 1024), to: source)

        await #expect(throws: (any Error).self) {
            try await Self.run(.copy, [source], to: volume.url, Self.context(.replace))
        }
        #expect(try Self.text(target) == "old")
        #expect(try Self.names(in: volume.url).filter { !$0.hasPrefix(".") } == ["big.bin"])
    }

    // MARK: A2 unreadable folders

    @Test func copyOfUnreadableFolderFails() async throws {
        let base = try FaultFixture.tempDir()
        defer { FaultFixture.remove(base) }
        let source = base.appendingPathComponent("src/d")
        let secret = source.appendingPathComponent("secret")
        try FaultFixture.write(Data("kept".utf8), to: secret.appendingPathComponent("s.txt"))
        let destination = base.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        await #expect(throws: TransferError.self) {
            try await FaultFixture.withUnreadable(secret) {
                try await Self.run(.copy, [source], to: destination)
            }
        }
    }

    @Test func crossVolumeMoveKeepsSourceWithUnreadableFolder() async throws {
        let volume = try ScratchVolume()
        let base = try FaultFixture.tempDir()
        defer { FaultFixture.remove(base) }
        let source = base.appendingPathComponent("d")
        let secret = source.appendingPathComponent("secret")
        try FaultFixture.write(Data("kept".utf8), to: secret.appendingPathComponent("s.txt"))

        await #expect(throws: TransferError.self) {
            try await FaultFixture.withUnreadable(secret) {
                try await Self.run(.move, [source], to: volume.url)
            }
        }
        #expect(try Self.text(secret.appendingPathComponent("s.txt")) == "kept")
    }

    // MARK: A3 verified cross-volume move

    /// Runs `action` once, at the first per-file progress event, with the name of the file just copied.
    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        private let action: @Sendable (String) -> Void
        init(_ action: @escaping @Sendable (String) -> Void) { self.action = action }
        func report(_ event: NodeEvent) {
            guard case .progress(_, _, let path) = event else { return }
            lock.lock()
            let first = !fired
            fired = true
            lock.unlock()
            if first { action(URL(fileURLWithPath: path ?? "").lastPathComponent) }
        }
    }

    @Test func crossVolumeMoveKeepsFileAddedDuringCopy() async throws {
        let volume = try ScratchVolume()
        let base = try FaultFixture.tempDir()
        defer { FaultFixture.remove(base) }
        let source = base.appendingPathComponent("d")
        try FaultFixture.write(Data("a".utf8), to: source.appendingPathComponent("a.txt"))
        let late = source.appendingPathComponent("late.txt")
        let once = Once { _ in try? Data("late".utf8).write(to: late) }

        await #expect(throws: TransferError.self) {
            try await Self.run(.move, [source], to: volume.url, Self.context(report: once.report))
        }
        #expect(try Self.text(late) == "late")
    }

    @Test func crossVolumeMoveKeepsFileChangedDuringCopy() async throws {
        let volume = try ScratchVolume()
        let base = try FaultFixture.tempDir()
        defer { FaultFixture.remove(base) }
        let source = base.appendingPathComponent("d")
        try FaultFixture.write(Data("aaaa".utf8), to: source.appendingPathComponent("a.txt"))
        try FaultFixture.write(Data("bbbb".utf8), to: source.appendingPathComponent("b.txt"))
        // Same size, so only comparing content can notice
        let once = Once { name in try? Data("CHNG".utf8).write(to: source.appendingPathComponent(name)) }

        await #expect(throws: TransferError.self) {
            try await Self.run(.move, [source], to: volume.url, Self.context(report: once.report))
        }
        let kept = try Self.names(in: source).map { try Self.text(source.appendingPathComponent($0)) }
        #expect(kept.contains("CHNG"))
    }

    @Test func crossVolumeMoveKeepsSourceWhenVolumeFills() async throws {
        let volume = try ScratchVolume()
        let base = try FaultFixture.tempDir()
        defer { FaultFixture.remove(base) }
        let source = base.appendingPathComponent("big.bin")
        try FaultFixture.write(Data(repeating: 7, count: 2 * 1024 * 1024), to: source)
        try volume.fill(leaving: 256 * 1024)

        await #expect(throws: TransferError.self) {
            try await Self.run(.move, [source], to: volume.url)
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func crossVolumeMoveKeepsSourceWhenVolumeEjects() async throws {
        let volume = try ScratchVolume()
        let base = try FaultFixture.tempDir()
        defer { FaultFixture.remove(base) }
        let source = base.appendingPathComponent("d")
        try FaultFixture.write(Data("a".utf8), to: source.appendingPathComponent("a.txt"))
        try FaultFixture.write(Data("b".utf8), to: source.appendingPathComponent("b.txt"))
        let once = Once { _ in try? volume.eject() }

        await #expect(throws: TransferError.self) {
            try await Self.run(.move, [source], to: volume.url, Self.context(report: once.report))
        }
        #expect(try Self.names(in: source) == ["a.txt", "b.txt"])
    }

    @Test func crossVolumeMoveRemovesSourceAfterVerifiedCopy() async throws {
        let volume = try ScratchVolume()
        let base = try FaultFixture.tempDir()
        defer { FaultFixture.remove(base) }
        let source = base.appendingPathComponent("d")
        try FaultFixture.write(Data("a".utf8), to: source.appendingPathComponent("sub/a.txt"))

        try await Self.run(.move, [source], to: volume.url)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try Self.text(volume.url.appendingPathComponent("d/sub/a.txt")) == "a")
    }

    // MARK: A4 self-nesting

    @Test(arguments: [OperationSpec.Kind.copy, .move])
    func folderCannotGoIntoItself(kind: OperationSpec.Kind) async throws {
        let base = try FaultFixture.tempDir()
        defer { FaultFixture.remove(base) }
        let folder = base.appendingPathComponent("d")
        let sub = folder.appendingPathComponent("sub")
        try FaultFixture.write(Data("x".utf8), to: sub.appendingPathComponent("f.txt"))

        for destination in [sub, folder] {
            await #expect(throws: TransferError.self) {
                try await Self.run(kind, [folder], to: destination, Self.context(.keepBoth))
            }
        }
        #expect(try Self.names(in: folder) == ["sub"])
        #expect(try Self.names(in: sub) == ["f.txt"])
    }

    @Test func folderCannotGoIntoItselfThroughAlias() async throws {
        let base = try FaultFixture.tempDir()
        defer { FaultFixture.remove(base) }
        let folder = base.appendingPathComponent("d")
        let sub = folder.appendingPathComponent("sub")
        try FaultFixture.write(Data("x".utf8), to: sub.appendingPathComponent("f.txt"))
        let alias = base.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: sub)

        await #expect(throws: TransferError.self) {
            try await Self.run(.copy, [folder], to: alias)
        }
        #expect(try Self.names(in: sub) == ["f.txt"])
    }

    @Test(arguments: [(OperationSpec.Kind.copy, ConflictDecision.replace),
                      (.move, .replace), (.copy, .mergeFolders), (.move, .mergeFolders)])
    func cannotOverwriteFolderHoldingTheSource(kind: OperationSpec.Kind, decision: ConflictDecision) async throws {
        let base = try FaultFixture.tempDir()
        defer { FaultFixture.remove(base) }
        let outer = base.appendingPathComponent("x")
        let source = outer.appendingPathComponent("y/x")
        let file = source.appendingPathComponent("f.txt")
        try FaultFixture.write(Data("keep".utf8), to: file)
        let sibling = outer.appendingPathComponent("sibling.txt")
        try FaultFixture.write(Data("keep".utf8), to: sibling)

        await #expect(throws: TransferError.self) {
            try await Self.run(kind, [source], to: base, Self.context(decision))
        }
        #expect(try Self.text(file) == "keep")
        #expect(try Self.text(sibling) == "keep")
    }

    @Test func replaceCannotDeleteAnotherSourceOfTheBatch() async throws {
        let base = try FaultFixture.tempDir()
        defer { FaultFixture.remove(base) }
        let incoming = base.appendingPathComponent("src/a")
        try FaultFixture.write(Data("new".utf8), to: incoming.appendingPathComponent("n.txt"))
        let destination = base.appendingPathComponent("dst")
        let nested = destination.appendingPathComponent("a/z.txt")
        try FaultFixture.write(Data("keep".utf8), to: nested)

        await #expect(throws: TransferError.self) {
            try await Self.run(.move, [incoming, nested], to: destination, Self.context(.replace))
        }
        #expect(try Self.text(nested) == "keep")
    }

    @Test func linkToFolderCanMoveIntoThatFolder() async throws {
        let base = try FaultFixture.tempDir()
        defer { FaultFixture.remove(base) }
        let folder = base.appendingPathComponent("d")
        try FaultFixture.write(Data("x".utf8), to: folder.appendingPathComponent("f.txt"))
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)

        try await Self.run(.move, [link], to: folder)
        #expect(try Self.names(in: folder) == ["f.txt", "link"])
    }

    // MARK: A5 symlinks

    static func linkTarget(_ url: URL) throws -> String {
        try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }

    @Test func linksInsideAFolderStayLinks() async throws {
        let base = try FaultFixture.tempDir()
        defer { FaultFixture.remove(base) }
        let outside = base.appendingPathComponent("outside")
        try FaultFixture.write(Data("x".utf8), to: outside.appendingPathComponent("big.txt"))
        let source = base.appendingPathComponent("src/d")
        try FaultFixture.write(Data("f".utf8), to: source.appendingPathComponent("f.txt"))
        let fm = FileManager.default
        try fm.createSymbolicLink(atPath: source.appendingPathComponent("relative").path, withDestinationPath: "f.txt")
        try fm.createSymbolicLink(at: source.appendingPathComponent("folder"), withDestinationURL: outside)
        try FaultFixture.danglingLink(at: source.appendingPathComponent("dangling"))
        try FaultFixture.cyclicLink(in: source)
        let destination = base.appendingPathComponent("dst")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        try await Self.run(.copy, [source], to: destination)

        let copy = destination.appendingPathComponent("d")
        #expect(try Self.names(in: copy) == ["dangling", "f.txt", "folder", "loop", "relative"])
        for name in ["relative", "folder", "dangling", "loop"] {
            #expect(try Self.linkTarget(copy.appendingPathComponent(name))
                    == Self.linkTarget(source.appendingPathComponent(name)))
        }
    }

    @Test(arguments: [OperationSpec.Kind.copy, .move])
    func topLevelLinksStayLinks(kind: OperationSpec.Kind) async throws {
        let base = try FaultFixture.tempDir()
        defer { FaultFixture.remove(base) }
        let folder = base.appendingPathComponent("folder")
        try FaultFixture.write(Data("x".utf8), to: folder.appendingPathComponent("f.txt"))
        let toFolder = base.appendingPathComponent("toFolder")
        try FileManager.default.createSymbolicLink(at: toFolder, withDestinationURL: folder)
        let dangling = try FaultFixture.danglingLink(at: base.appendingPathComponent("dangling"))
        let target = try Self.linkTarget(dangling)
        let destination = base.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        try await Self.run(kind, [toFolder, dangling], to: destination)

        #expect(try Self.linkTarget(destination.appendingPathComponent("toFolder")) == folder.path)
        #expect(try Self.linkTarget(destination.appendingPathComponent("dangling")) == target)
    }

    @Test func crossVolumeMoveCarriesLinks() async throws {
        let volume = try ScratchVolume()
        let base = try FaultFixture.tempDir()
        defer { FaultFixture.remove(base) }
        let source = base.appendingPathComponent("d")
        try FaultFixture.write(Data("f".utf8), to: source.appendingPathComponent("f.txt"))
        let target = try Self.linkTarget(try FaultFixture.danglingLink(at: source.appendingPathComponent("dangling")))
        try FaultFixture.cyclicLink(in: source)

        try await Self.run(.move, [source], to: volume.url)

        #expect(!FileManager.default.fileExists(atPath: source.path))
        let moved = volume.url.appendingPathComponent("d")
        #expect(try Self.linkTarget(moved.appendingPathComponent("dangling")) == target)
        #expect(try Self.linkTarget(moved.appendingPathComponent("loop")) == source.path)
    }

    @Test func danglingLinkAtTheDestinationIsAConflict() async throws {
        let base = try FaultFixture.tempDir()
        defer { FaultFixture.remove(base) }
        let source = base.appendingPathComponent("f.txt")
        try FaultFixture.write(Data("new".utf8), to: source)
        let destination = base.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let link = try FaultFixture.danglingLink(at: destination.appendingPathComponent("f.txt"))
        let target = try Self.linkTarget(link)

        try await Self.run(.copy, [source], to: destination, Self.context(.keepBoth))

        #expect(try Self.linkTarget(link) == target)
        #expect(try Self.text(destination.appendingPathComponent("f 2.txt")) == "new")
    }

    @Test func linkToFolderIsNotOfferedAsAMerge() async throws {
        let base = try FaultFixture.tempDir()
        defer { FaultFixture.remove(base) }
        let folder = base.appendingPathComponent("folder")
        try FaultFixture.write(Data("x".utf8), to: folder.appendingPathComponent("f.txt"))
        let link = base.appendingPathComponent("name")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        let destination = base.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("name"),
                                                withIntermediateDirectories: true)
        let seen = Seen()
        let context = NodeContext(operationID: UUID(), report: { _ in }, resolveConflicts: { conflicts in
            seen.set(conflicts.map(\.bothDirectories))
            return [:]
        })

        try await Self.run(.copy, [link], to: destination, context)
        #expect(seen.value == [false])
    }

    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Bool] = []
        func set(_ value: [Bool]) { lock.lock(); stored = value; lock.unlock() }
        var value: [Bool] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    // MARK: A6 exclusive copy

    /// Copies or moves [first, second]; `foreign` appears at the second destination once the first has landed.
    static func racedTransfer(_ kind: OperationSpec.Kind, into destination: URL, base: URL,
                              foreign: @escaping @Sendable (URL) -> Void, second: String) async throws {
        let first = base.appendingPathComponent("src/first.txt")
        try FaultFixture.write(Data("first".utf8), to: first)
        let once = Once { _ in foreign(destination.appendingPathComponent(second)) }
        try await run(kind, [first, base.appendingPathComponent("src/\(second)")], to: destination,
                      context(report: once.report))
    }

    @Test func fileAppearingAfterTheCheckIsNotOverwritten() async throws {
        let base = try FaultFixture.tempDir()
        defer { FaultFixture.remove(base) }
        try FaultFixture.write(Data("mine".utf8), to: base.appendingPathComponent("src/b.txt"))
        let destination = base.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        await #expect(throws: TransferError.self) {
            try await Self.racedTransfer(.copy, into: destination, base: base,
                                         foreign: { try? Data("foreign".utf8).write(to: $0) }, second: "b.txt")
        }
        #expect(try Self.text(destination.appendingPathComponent("b.txt")) == "foreign")
    }

    @Test func fileAppearingOnAnotherVolumeIsNotOverwritten() async throws {
        let volume = try ScratchVolume()
        let base = try FaultFixture.tempDir()
        defer { FaultFixture.remove(base) }
        let source = base.appendingPathComponent("src/b.txt")
        try FaultFixture.write(Data("mine".utf8), to: source)

        await #expect(throws: TransferError.self) {
            try await Self.racedTransfer(.move, into: volume.url, base: base,
                                         foreign: { try? Data("foreign".utf8).write(to: $0) }, second: "b.txt")
        }
        #expect(try Self.text(volume.url.appendingPathComponent("b.txt")) == "foreign")
        #expect(try Self.text(source) == "mine")
    }

    @Test func folderAppearingAfterTheCheckIsNotMergedInto() async throws {
        let base = try FaultFixture.tempDir()
        defer { FaultFixture.remove(base) }
        try FaultFixture.write(Data("mine".utf8), to: base.appendingPathComponent("src/d/m.txt"))
        let destination = base.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        await #expect(throws: TransferError.self) {
            try await Self.racedTransfer(.copy, into: destination, base: base,
                                         foreign: { try? FaultFixture.write(to: $0.appendingPathComponent("foreign.txt")) },
                                         second: "d")
        }
        #expect(try Self.names(in: destination.appendingPathComponent("d")) == ["foreign.txt"])
    }
}
