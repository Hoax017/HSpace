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
}
