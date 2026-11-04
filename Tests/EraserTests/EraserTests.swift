import Testing
import Foundation
import Eraser
import NSpaceContracts

/// Black-box acceptance: real physical I/O on temp fixtures (no fakes or mocks).
/// Permanent deletion is the only irreversible operation in this repo, so tests of the **guards** matter more than tests that it "can delete".
@Suite struct EraserTests {
    static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nspace-er-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func context() -> NodeContext {
        NodeContext(operationID: UUID(), report: { _ in }, resolveConflicts: { _ in [:] })
    }

    // MARK: Fence guard (blast radius): pure logic, the Oracle needs no file system

    @Test func fenceAcceptsInsideRejectsOutsideAndRootItself() {
        let fence = URL(fileURLWithPath: "/tmp/fence")
        #expect(EraserLimits.isFenced(URL(fileURLWithPath: "/tmp/fence/a.txt"), by: fence))
        #expect(EraserLimits.isFenced(URL(fileURLWithPath: "/tmp/fence/sub/deep.txt"), by: fence))
        #expect(!EraserLimits.isFenced(URL(fileURLWithPath: "/tmp/fence"), by: fence))       // the fence itself
        #expect(!EraserLimits.isFenced(URL(fileURLWithPath: "/tmp/other/a.txt"), by: fence))
        // Similar prefix but different directory: /tmp/fence-evil must never pass the /tmp/fence fence
        #expect(!EraserLimits.isFenced(URL(fileURLWithPath: "/tmp/fence-evil/a.txt"), by: fence))
        // Path traversal spelled out stays outside the fence after standardization
        #expect(!EraserLimits.isFenced(URL(fileURLWithPath: "/tmp/fence/../other/a.txt"), by: fence))
    }

    @Test func refusesSourcesOutsideTheFence() async throws {
        let dir = try Self.tempDir()
        let outside = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: outside) }
        let inside = dir.appendingPathComponent("in.txt")
        let stray = outside.appendingPathComponent("out.txt")
        try Data("x".utf8).write(to: inside)
        try Data("x".utf8).write(to: stray)

        await #expect(throws: (any Error).self) {
            _ = try await EraserNode().execute(
                OperationSpec(kind: .delete, sources: [inside, stray], destination: dir),
                context: Self.context())
        }
        // Whole batch refused: the item inside the fence must **not** be deleted either (no "delete half")
        #expect(FileManager.default.fileExists(atPath: inside.path))
        #expect(FileManager.default.fileExists(atPath: stray.path))
    }

    @Test func refusesWithoutFence() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("in.txt")
        try Data("x".utf8).write(to: f)
        await #expect(throws: (any Error).self) {
            _ = try await EraserNode().execute(
                OperationSpec(kind: .delete, sources: [f]),   // no destination
                context: Self.context())
        }
        #expect(FileManager.default.fileExists(atPath: f.path))
    }

    // MARK: Real deletion + truthful partial failure reports

    @Test func erasesFilesAndDirectoriesInsideFence() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("gone.txt")
        let sub = dir.appendingPathComponent("gonedir")
        try Data("x".utf8).write(to: file)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("y".utf8).write(to: sub.appendingPathComponent("nested.txt"))

        let r = try await EraserNode().execute(
            OperationSpec(kind: .delete, sources: [file, sub], destination: dir),
            context: Self.context())
        #expect(r.filesDone == 2)
        #expect(r.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: sub.path))
        #expect(r.trashedItems.isEmpty)      // permanent deletion has no undoable location, it must not pretend to have one
    }

    @Test func partialFailureReportsWhatWasErased() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real.txt")
        try Data("x".utf8).write(to: real)
        let ghost = dir.appendingPathComponent("ghost.txt")     // does not exist → certain to fail

        let r = try await EraserNode().execute(
            OperationSpec(kind: .delete, sources: [real, ghost], destination: dir),
            context: Self.context())
        #expect(r.filesDone == 1)
        #expect(r.failures.count == 1)
        #expect(r.failures.first?.url == ghost)
        #expect(!FileManager.default.fileExists(atPath: real.path))
    }

    @Test func totalFailureThrows() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: (any Error).self) {
            _ = try await EraserNode().execute(
                OperationSpec(kind: .delete,
                              sources: [dir.appendingPathComponent("ghost.txt")], destination: dir),
                context: Self.context())
        }
    }
}
