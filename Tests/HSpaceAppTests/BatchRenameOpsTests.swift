import AppKit
import BatchRename
import HSpaceKernel
import HSpaceTestSupport
import Testing
@testable import HSpaceApp

/// Through the real pod and the window's undo stack. No window is involved.
@MainActor @Suite struct BatchRenameOpsTests {
    private func coordinator() -> FileOpsCoordinator {
        let coordinator = FileOpsCoordinator(kernel: OperationKernel(),
                                             grid: PaneGridController(initialDirectory: URL(fileURLWithPath: "/")))
        coordinator.undoManager.groupsByEvent = false
        return coordinator
    }

    private func names(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    @Test func aBatchIsOneUndoAndOneRedo() async throws {
        let dir = try FaultFixture.tempDir("hspace-rename-ops")
        defer { FaultFixture.remove(dir) }
        let sources = ["a", "b", "c"].map { dir.appendingPathComponent($0) }
        for url in sources { try FaultFixture.write(to: url) }
        let coordinator = coordinator()
        let ops = BatchRenameOps(coordinator: coordinator)
        let plan = try BatchRenamePlanner.plan(sources: sources, names: ["x", "y", "z"])

        coordinator.undoManager.beginUndoGrouping()
        _ = try await ops.apply(plan) { _, _ in }
        coordinator.undoManager.endUndoGrouping()
        #expect(try names(in: dir) == ["x", "y", "z"])
        #expect(coordinator.undoManager.undoActionName == L10n.t("undo.batchRename"))

        coordinator.undoManager.undo()
        await ops.lastReversal?.value
        #expect(try names(in: dir) == ["a", "b", "c"])
        #expect(!coordinator.undoManager.canUndo)

        coordinator.undoManager.redo()
        await ops.lastReversal?.value
        #expect(try names(in: dir) == ["x", "y", "z"])
    }

    @Test func aFailedBatchLeavesNothingToUndo() async throws {
        let dir = try FaultFixture.tempDir("hspace-rename-ops")
        defer { FaultFixture.remove(dir) }
        let source = dir.appendingPathComponent("a")
        try FaultFixture.write(to: source)
        let coordinator = coordinator()
        let ops = BatchRenameOps(coordinator: coordinator)
        let plan = try BatchRenamePlanner.plan(sources: [source], names: ["x"])
        try FaultFixture.write(to: dir.appendingPathComponent("x"))

        await #expect(throws: BatchRenameError.self) { _ = try await ops.apply(plan) { _, _ in } }
        #expect(!coordinator.undoManager.canUndo)
    }
}

@MainActor @Suite struct BatchRenameModelTests {
    @Test func aBadExpressionIsShownAndBlocksApplying() async throws {
        let model = BatchRenameModel(items: [RenameItem(url: URL(fileURLWithPath: "/nonexistent/a"))],
                                     steps: [.replace(ReplaceStep(find: "(", replacement: "", isRegex: true))])
        await model.refresh()
        #expect(model.stepError != nil)
        #expect(!model.canApply)
    }

    @Test func thePreviewFollowsTheSteps() async throws {
        let dir = try FaultFixture.tempDir("hspace-rename-model")
        defer { FaultFixture.remove(dir) }
        let a = dir.appendingPathComponent("a.txt"), taken = dir.appendingPathComponent("b.txt")
        try FaultFixture.write(to: a)
        try FaultFixture.write(to: taken)
        let model = BatchRenameModel(items: [RenameItem(url: a)], steps: [])
        await model.refresh()
        #expect(!model.canApply)
        #expect(model.summary == L10n.t("rename.summary.none"))

        model.setSteps([.replace(ReplaceStep(find: "a", replacement: "c"))])
        await model.refresh()
        #expect(model.canApply)
        #expect(model.plan?.rows.first?.newName == "c.txt")

        model.setSteps([.replace(ReplaceStep(find: "a", replacement: "b"))])
        await model.refresh()
        #expect(!model.canApply)
        #expect(model.plan?.blockedCount == 1)
    }

    @Test func everyStepKindSurvivesItsRow() {
        let steps: [RenameStep] = [
            .replace(ReplaceStep(find: "a", replacement: "b", isRegex: true, caseSensitive: true, firstMatchOnly: true, scope: .wholeName)),
            .changeCase(.sentence, scope: .fileExtension),
            .insert(text: "x", position: .replaceName),
            .sequence(SequenceStep(start: 5, increment: 2, width: 3, position: .prefix, separator: "_", restartPerFolder: true)),
            .date(DateStep(source: .created, format: "yy", position: .suffix, separator: "-")),
        ]
        for step in steps { #expect(RenameStepRow(step: step).step == step) }
    }

    @Test func theSheetBuildsWithoutAWindowServerSession() {
        let host = NSWindow()
        let grid = PaneGridController(initialDirectory: URL(fileURLWithPath: "/"))
        let ops = BatchRenameOps(coordinator: FileOpsCoordinator(kernel: OperationKernel(), grid: grid))
        let sheet = BatchRenameSheetController(items: [RenameItem(url: URL(fileURLWithPath: "/a"))], steps: [], ops: ops, host: host)
        #expect(sheet.model.items.count == 1)
    }
}
