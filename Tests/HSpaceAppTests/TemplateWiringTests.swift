import FileTemplates
import Foundation
import HSpaceContracts
import HSpaceKernel
import HSpaceTestSupport
import OperationHistory
import Testing
import Transfer
@testable import HSpaceApp

/// Through the real kernel and Transfer.
@MainActor @Suite struct TemplateWiringTests {
    private func setup() async throws -> (dir: URL, library: TemplateLibrary, target: URL, coordinator: FileOpsCoordinator) {
        let dir = try FaultFixture.tempDir("hspace-templatewiring")
        let library = TemplateLibrary(folder: dir.appendingPathComponent("templates"))
        try library.prepareFolder()
        let target = dir.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let kernel = OperationKernel()
        await kernel.register(TransferNode(), for: [.copy, .move, .duplicate])
        let coordinator = FileOpsCoordinator(kernel: kernel, grid: PaneGridController(initialDirectory: URL(fileURLWithPath: "/")))
        return (dir, library, target, coordinator)
    }

    private func create(_ template: FileTemplate, in target: URL, _ coordinator: FileOpsCoordinator) async -> OperationReceipt? {
        await withCheckedContinuation { done in
            coordinator.newItem(from: template, in: target, revealIn: nil) { done.resume(returning: $0) }
        }
    }

    @Test func aCopyArrivesUnderTheExpandedName() async throws {
        let (dir, library, target, coordinator) = try await setup()
        defer { FaultFixture.remove(dir) }
        try FaultFixture.write(Data("body".utf8), to: library.folder.appendingPathComponent("Log $date(yyyy).md"))
        let template = try #require(try library.templates().first)
        let receipt = await create(template, in: target, coordinator)
        let year = Calendar.current.component(.year, from: Date())
        let landed = target.appendingPathComponent("Log \(year).md")
        #expect(receipt?.createdURLs == [landed])
        #expect(try String(contentsOf: landed, encoding: .utf8) == "body")
    }

    @Test func aTakenNameCountsInsteadOfAsking() async throws {
        let (dir, library, target, coordinator) = try await setup()
        defer { FaultFixture.remove(dir) }
        try FaultFixture.write(to: library.folder.appendingPathComponent("Note.txt"))
        try FaultFixture.write(Data("mine".utf8), to: target.appendingPathComponent("Note.txt"))
        let template = try #require(try library.templates().first)
        let receipt = await create(template, in: target, coordinator)
        #expect(receipt?.createdURLs.first?.lastPathComponent == "Note 2.txt")
        #expect(try String(contentsOf: target.appendingPathComponent("Note.txt"), encoding: .utf8) == "mine")
    }

    @Test func aFolderTemplateCopiesWhole() async throws {
        let (dir, library, target, coordinator) = try await setup()
        defer { FaultFixture.remove(dir) }
        try FaultFixture.write(to: library.folder.appendingPathComponent("Project/src/main.txt"))
        let template = try #require(try library.templates().first)
        _ = await create(template, in: target, coordinator)
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("Project/src/main.txt").path))
    }

    @Test func aMissingTemplateFailsAndLeavesNothing() async throws {
        let (dir, library, target, coordinator) = try await setup()
        defer { FaultFixture.remove(dir) }
        let file = library.folder.appendingPathComponent("Gone.txt")
        try FaultFixture.write(to: file)
        let template = try #require(try library.templates().first)
        try FileManager.default.removeItem(at: file)
        #expect(await create(template, in: target, coordinator) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    @Test func theTrashIsRefused() async throws {
        let (dir, library, _, coordinator) = try await setup()
        defer { FaultFixture.remove(dir) }
        try FaultFixture.write(to: library.folder.appendingPathComponent("Note.txt"))
        let template = try #require(try library.templates().first)
        #expect(await create(template, in: TrashLocation.userTrash, coordinator) == nil)
    }

    @Test func aNewItemIsRecordedAsCreated() async throws {
        let (dir, library, target, coordinator) = try await setup()
        defer { FaultFixture.remove(dir) }
        let store = HistoryStore(directory: dir.appendingPathComponent("support"))
        coordinator.history = store
        try FaultFixture.write(to: library.folder.appendingPathComponent("Note.txt"))
        let template = try #require(try library.templates().first)
        _ = await create(template, in: target, coordinator)
        #expect(await store.groups().first?.steps == [.created(path: target.appendingPathComponent("Note.txt").path)])
    }
}
