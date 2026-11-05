import ArchiveEngine
import AppKit
import HSpaceContracts
import HSpaceKernel
import HSpaceTestSupport
import Testing
import Transfer
@testable import HSpaceApp

private struct KeepBothArbiter: ConflictArbiter {
    func arbitrate(operation id: UUID, conflicts: [FileConflict]) async -> [URL: ConflictDecision]? {
        Dictionary(uniqueKeysWithValues: conflicts.map { ($0.source, .keepBoth) })
    }
}

/// Through the real kernel and Transfer, with real tar archives
@MainActor @Suite struct ArchiveBrowserTests {
    private func fixture(_ files: [String: String], in dir: URL) throws -> URL {
        let source = try FaultFixture.tempDir("hspace-browser-src")
        defer { FaultFixture.remove(source) }
        for (name, body) in files {
            try FaultFixture.write(Data(body.utf8), to: source.appendingPathComponent(name))
        }
        let archive = dir.appendingPathComponent("fixture.zip")
        let process = try Process.run(URL(fileURLWithPath: "/usr/bin/tar"),
                                      arguments: ["-a", "-cf", archive.path, "-C", source.path, "."])
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return archive
    }

    private func coordinator() async -> FileOpsCoordinator {
        let kernel = OperationKernel()
        await kernel.register(TransferNode(), for: [.copy, .move, .duplicate])
        await kernel.setArbiter(KeepBothArbiter())
        return FileOpsCoordinator(kernel: kernel, grid: PaneGridController(initialDirectory: URL(fileURLWithPath: "/")))
    }

    private func land(_ urls: [URL], into directory: URL, with coordinator: FileOpsCoordinator) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            coordinator.landExtracted(urls, into: directory) { done.resume() }
        }
    }

    @Test func stagedItemsLandThroughTransferWithoutOverwriting() async throws {
        let dir = try FaultFixture.tempDir("hspace-browser")
        defer { FaultFixture.remove(dir) }
        let archive = try fixture(["wanted.txt": "new", "ignored.txt": "no"], in: dir)
        let target = try FaultFixture.tempDir("hspace-browser-target")
        defer { FaultFixture.remove(target) }
        try FaultFixture.write(Data("old".utf8), to: target.appendingPathComponent("wanted.txt"))
        let model = ArchiveBrowserModel(archive: archive)
        try await model.load()
        #expect(model.itemCount == 2)

        let node = try #require(model.root?.children.first { $0.name == "wanted.txt" })
        let staged = try await model.stage([node])
        await land(staged.items, into: target, with: await coordinator())
        model.discard(staged.scratch)

        let names = try FileManager.default.contentsOfDirectory(atPath: target.path).sorted()
        #expect(names == ["wanted 2.txt", "wanted.txt"])
        #expect(try String(contentsOf: target.appendingPathComponent("wanted.txt"), encoding: .utf8) == "old")
        #expect(!FileManager.default.fileExists(atPath: staged.scratch.path))
    }

    @Test func aDamagedArchiveFailsTheStage() async throws {
        let dir = try FaultFixture.tempDir("hspace-browser")
        defer { FaultFixture.remove(dir) }
        let archive = try fixture(["a.txt": "a"], in: dir)
        let model = ArchiveBrowserModel(archive: archive)
        try await model.load()
        let node = try #require(model.root?.children.first)
        try Data("damaged".utf8).write(to: archive)

        await #expect(throws: (any Error).self) { _ = try await model.stage([node]) }
    }

    @Test func itemsInsideASelectedFolderAreNotTakenTwice() async throws {
        let dir = try FaultFixture.tempDir("hspace-browser")
        defer { FaultFixture.remove(dir) }
        let archive = try fixture(["sub/a.txt": "a", "sub2/b.txt": "b"], in: dir)
        let model = ArchiveBrowserModel(archive: archive)
        try await model.load()
        let root = try #require(model.root)
        let folder = try #require(root.children.first { $0.name == "sub" })
        let inner = try #require(folder.children.first)
        let other = try #require(root.children.first { $0.name == "sub2" })

        #expect(ArchiveBrowserModel.topmost([folder, inner, other]).map(\.name) == ["sub", "sub2"])
    }

    @Test func previewsComeOutOnceAndFoldersAreSkipped() async throws {
        let dir = try FaultFixture.tempDir("hspace-browser")
        defer { FaultFixture.remove(dir) }
        let archive = try fixture(["sub/a.txt": "a", "b.txt": "b"], in: dir)
        let model = ArchiveBrowserModel(archive: archive)
        try await model.load()
        defer { model.discardAll() }
        let root = try #require(model.root)

        let urls = try await model.previewURLs(root.children)
        #expect(urls.map(\.lastPathComponent) == ["b.txt"])
        #expect(try String(contentsOf: urls[0], encoding: .utf8) == "b")

        // Served from the temporary folder: the archive is not read a second time
        try Data("damaged".utf8).write(to: archive)
        #expect(try await model.previewURLs(root.children) == urls)
    }

    @Test func nothingToPreviewIsNotAnError() async throws {
        let dir = try FaultFixture.tempDir("hspace-browser")
        defer { FaultFixture.remove(dir) }
        let archive = try fixture(["sub/a.txt": "a"], in: dir)
        let model = ArchiveBrowserModel(archive: archive)
        try await model.load()
        #expect(try await model.previewURLs(model.root?.children ?? []).isEmpty)
    }

    @Test func closingTheWindowEndsThePreviews() async throws {
        let dir = try FaultFixture.tempDir("hspace-browser")
        defer { FaultFixture.remove(dir) }
        let archive = try fixture(["a.txt": "a"], in: dir)
        let model = ArchiveBrowserModel(archive: archive)
        try await model.load()
        let urls = try await model.previewURLs(model.root?.children ?? [])

        model.discardAll()

        #expect(!FileManager.default.fileExists(atPath: urls[0].path))
        #expect(try await model.previewURLs(model.root?.children ?? []).isEmpty == false)
        model.discardAll()
    }

    @Test func closingTheWindowRemovesWhatWasTakenOut() async throws {
        let dir = try FaultFixture.tempDir("hspace-browser")
        defer { FaultFixture.remove(dir) }
        let archive = try fixture(["a.txt": "a"], in: dir)
        let controller = ArchiveBrowserWindowController(archive: archive, coordinator: nil)
        controller.reload()
        await controller.waitUntilIdle()
        let node = try #require(controller.model.root?.children.first)
        let staged = try await controller.model.stage([node])

        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        #expect(!FileManager.default.fileExists(atPath: staged.scratch.path))
    }
}
