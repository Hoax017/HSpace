import Foundation
import FileMetadata
import HSpaceContracts
import HSpaceKernel
import HSpaceTestSupport
import Testing
@testable import HSpaceApp

@Suite struct CommentEditStartTests {
    @Test func oneCommentIsShown() {
        #expect(CommentEditStart(comments: ["a", "a"]) == CommentEditStart(comments: ["a"]))
        #expect(CommentEditStart(comments: ["a"]).text == "a")
        #expect(!CommentEditStart(comments: ["a"]).differs)
    }

    @Test func differingCommentsStartEmptyAndSaySo() {
        let start = CommentEditStart(comments: ["a", "b"])
        #expect(start.text.isEmpty)
        #expect(start.differs)
    }
}

/// Stands in for Finder: tests must not send it Apple Events
private final class RecordingFinder: FinderCommentPushing, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func push(comment: String, to urls: [URL]) async throws {
        lock.withLock { stored.append(comment) }
    }

    var comments: [String] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

@MainActor @Suite struct CommentCoordinatorTests {
    @Test func aChangeReachesDiskAndFinderAndCanBeUndone() async throws {
        let dir = try FaultFixture.tempDir("hspace-comment")
        defer { FaultFixture.remove(dir) }
        let file = dir.appendingPathComponent("a")
        try FaultFixture.write(to: file)
        let coordinator = FileOpsCoordinator(kernel: OperationKernel(),
                                             grid: PaneGridController(initialDirectory: URL(fileURLWithPath: "/")))
        let finder = RecordingFinder()
        coordinator.finderComments = finder
        let undo = coordinator.undoManager
        undo.groupsByEvent = false

        undo.beginUndoGrouping()
        coordinator.applyMetadata(.comment("note"), to: [file], actionName: "Comment")
        await eventually("pushed") { finder.comments == ["note"] }
        undo.endUndoGrouping()
        #expect(try Engines.metadata.comment(of: file) == "note")

        undo.undo()
        await eventually("undo pushed") { finder.comments == ["note", ""] }
        #expect(try Engines.metadata.comment(of: file) == nil)
    }

    @Test func aTagChangeDoesNotBotherFinder() async throws {
        let dir = try FaultFixture.tempDir("hspace-comment")
        defer { FaultFixture.remove(dir) }
        let file = dir.appendingPathComponent("a")
        try FaultFixture.write(to: file)
        let coordinator = FileOpsCoordinator(kernel: OperationKernel(),
                                             grid: PaneGridController(initialDirectory: URL(fileURLWithPath: "/")))
        let finder = RecordingFinder()
        coordinator.finderComments = finder
        coordinator.applyMetadata(.tags(add: [FinderTag(name: "Red", color: .red)], remove: []), to: [file], actionName: "Tags")
        try await eventually("tagged") { try !Engines.metadata.tags(of: file).isEmpty }
        try await Task.sleep(for: .milliseconds(50))
        #expect(finder.comments.isEmpty)
    }
}
