import Testing
import Foundation
import LocalOps
import HSpaceContracts

/// Black-box acceptance: only through the Contract public surface; real physical I/O on temp fixture trees (no fakes or mocks)
@Suite struct LocalOpsTests {
    static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hspace-lo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func context() -> NodeContext {
        NodeContext(operationID: UUID(), report: { _ in }, resolveConflicts: { _ in [:] })
    }

    // MARK: uniqueName pure logic (Oracle: no file system needed)

    @Test func uniqueNameAppendsSequence() {
        let dir = URL(fileURLWithPath: "/tmp/x")
        let existing = Set(["untitled folder", "untitled folder 2"])
        let name = uniqueName(base: "untitled folder", ext: "", in: dir,
                              existsCheck: { existing.contains($0.lastPathComponent) })
        #expect(name == "untitled folder 3")
        let free = uniqueName(base: "Résumé", ext: "txt", in: dir, existsCheck: { _ in false })
        #expect(free == "Résumé.txt")
    }

    // MARK: New folder (first + duplicate numbering)

    @Test func newFolderCreatesAndSequences() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let r1 = try await LocalOpsNode().execute(
            OperationSpec(kind: .newFolder, sources: [], destination: dir, newName: "untitled folder"),
            context: Self.context())
        #expect(r1.createdURLs.first?.lastPathComponent == "untitled folder")
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: r1.createdURLs[0].path, isDirectory: &isDir))
        #expect(isDir.boolValue)

        let r2 = try await LocalOpsNode().execute(
            OperationSpec(kind: .newFolder, sources: [], destination: dir, newName: "untitled folder"),
            context: Self.context())
        #expect(r2.createdURLs.first?.lastPathComponent == "untitled folder 2")
    }

    // MARK: New file

    @Test func newFileCreatesEmpty() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try await LocalOpsNode().execute(
            OperationSpec(kind: .newFile, sources: [], destination: dir, newName: "untitled"),
            context: Self.context())
        let url = try #require(r.createdURLs.first)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: url).isEmpty)
    }

    // MARK: Rename (success + result URL)

    @Test func renameMovesInPlace() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("old.txt")
        try Data("x".utf8).write(to: src)
        let r = try await LocalOpsNode().execute(
            OperationSpec(kind: .rename, sources: [src], newName: "new.txt"),
            context: Self.context())
        #expect(!FileManager.default.fileExists(atPath: src.path))
        let dst = dir.appendingPathComponent("new.txt")
        #expect(FileManager.default.fileExists(atPath: dst.path))
        #expect(r.createdURLs.first == dst)
    }

    // MARK: Rename conflict → external class

    @Test func renameOntoExistingIsExternalError() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.txt")
        let b = dir.appendingPathComponent("b.txt")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)
        do {
            _ = try await LocalOpsNode().execute(
                OperationSpec(kind: .rename, sources: [a], newName: "b.txt"),
                context: Self.context())
            Issue.record("Expected an error")
        } catch let e as any ClassifiedError {
            #expect(e.errorClass == .external)
        }
    }

    // MARK: Invalid spec → logic class

    @Test func emptyNameIsLogicError() async {
        do {
            _ = try await LocalOpsNode().execute(
                OperationSpec(kind: .rename, sources: [URL(fileURLWithPath: "/tmp/x")], newName: ""),
                context: Self.context())
            Issue.record("Expected an error")
        } catch let e as any ClassifiedError {
            #expect(e.errorClass == .logic)
        } catch {
            Issue.record("Unclassified error (violates P6.4):\(error)")
        }
    }

    // MARK: Move to Trash (records original → Trash pairs, undoable by moving back)

    @Test func trashRecordsPairsAndRemovesSource() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("doomed.txt")
        try Data("bye".utf8).write(to: src)

        let r = try await LocalOpsNode().execute(
            OperationSpec(kind: .trash, sources: [src]),
            context: Self.context())
        #expect(!FileManager.default.fileExists(atPath: src.path))
        let pair = try #require(r.trashedItems.first)
        #expect(pair.original == src)
        #expect(FileManager.default.fileExists(atPath: pair.trashed.path))
        // Undo semantics check: moving the Trash location back to the original restores it fully
        try FileManager.default.moveItem(at: pair.trashed, to: pair.original)
        #expect(try Data(contentsOf: src) == Data("bye".utf8))
    }
    // MARK: Partial failure (an existing defect caught by adversarial review, v0.19.18)

    /// When one item in a mixed selection cannot move, the old implementation threw midway: **items already really removed were lost with the throw**.
    /// The kernel stores receipts only on the success path, so the coordinator got nil and neither registered undo, showed a toast, nor reported an error.
    /// The user's files really went to Trash, with no undo and no idea what happened.
    /// This path got easier to hit once Trash became browsable (items inside Trash cannot be moved there), so it had to be fixed.
    @Test func partialTrashFailureStillReportsWhatLanded() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("lands.txt")
        try Data("x".utf8).write(to: real)
        let ghost = dir.appendingPathComponent("ghost-never-existed.txt")   // the item certain to fail

        let r = try await LocalOpsNode().execute(
            OperationSpec(kind: .trash, sources: [real, ghost]),
            context: Self.context())

        // The item that really landed must be reported (undo depends on it)
        #expect(r.trashedItems.count == 1, "got \(r.trashedItems.count) items")
        #expect(r.trashedItems.first?.original == real)
        #expect(!FileManager.default.fileExists(atPath: real.path))
        // The failed item must be reported truthfully, never silently
        #expect(r.failures.count == 1, "got \(r.failures.count) failures")
        #expect(r.failures.first?.url == ghost)
        #expect(r.failures.first?.message.isEmpty == false)
        #expect(r.filesDone == 1)                       // the count tells the truth: 1 succeeded, 1 failed
        // Clean up the item that landed in the real Trash
        if let t = r.trashedItems.first?.trashed { try? FileManager.default.removeItem(at: t) }
    }

    /// But **total failure** must still throw: partial-success semantics must not dress up "nothing done" as completed
    @Test func totalTrashFailureStillThrows() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ghost = dir.appendingPathComponent("ghost-never-existed.txt")
        await #expect(throws: (any Error).self) {
            _ = try await LocalOpsNode().execute(
                OperationSpec(kind: .trash, sources: [ghost]),
                context: Self.context())
        }
    }
    // MARK: newFile with contents (⌘V pastes clipboard contents as a new file, v0.19.20)

    @Test func newFileWritesProvidedContents() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = Data("hello from clipboard".utf8)
        let r = try await LocalOpsNode().execute(
            OperationSpec(kind: .newFile, sources: [], destination: dir,
                          newName: "Pasted Text.txt", contents: payload),
            context: Self.context())
        let url = try #require(r.createdURLs.first)
        #expect(url.lastPathComponent == "Pasted Text.txt")
        #expect(try Data(contentsOf: url) == payload)
        #expect(r.bytesDone == Int64(payload.count))
    }

    /// On a name clash the number must go **before the extension**: `Pasted Text 2.txt`, not `Pasted Text.txt 2`
    @Test func newFileWithContentsDedupesBeforeExtension() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = Data("x".utf8)
        let spec = OperationSpec(kind: .newFile, sources: [], destination: dir,
                                 newName: "Pasted Text.txt", contents: payload)
        let first = try await LocalOpsNode().execute(spec, context: Self.context())
        let second = try await LocalOpsNode().execute(spec, context: Self.context())
        #expect(first.createdURLs.first?.lastPathComponent == "Pasted Text.txt")
        #expect(second.createdURLs.first?.lastPathComponent == "Pasted Text 2.txt",
                "got\(second.createdURLs.first?.lastPathComponent ?? "nil")")
    }

    /// Without contents the naming is **entirely unchanged** (this change must not skew existing newFile behaviour)
    @Test func newFileWithoutContentsKeepsLegacyNaming() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try await LocalOpsNode().execute(
            OperationSpec(kind: .newFile, sources: [], destination: dir, newName: "untitled"),
            context: Self.context())
        #expect(r.createdURLs.first?.lastPathComponent == "untitled")
        #expect(r.bytesDone == 0)
        #expect(try Data(contentsOf: r.createdURLs[0]).isEmpty)
    }
}
