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
}
