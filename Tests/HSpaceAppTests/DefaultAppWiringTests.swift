import AppKit
import FileMetadata
import HSpaceContracts
import HSpaceKernel
import HSpaceTestSupport
import Testing
import UniformTypeIdentifiers
@testable import HSpaceApp

private final class MemoryRegistry: DefaultAppRegistry, @unchecked Sendable {
    private let lock = NSLock()
    private var apps: [String: URL] = [:]

    init(_ apps: [String: URL] = [:]) { self.apps = apps }

    func defaultApp(for type: UTType) -> URL? {
        lock.withLock { apps[type.identifier] }
    }

    func setDefaultApp(_ app: URL, for type: UTType) async throws {
        lock.withLock { apps[type.identifier] = app }
    }
}

@MainActor @Suite struct DefaultAppCoordinatorTests {
    private func changed(_ coordinator: FileOpsCoordinator, to app: URL) async -> DefaultAppChange? {
        await withCheckedContinuation { finished in
            coordinator.setDefaultApp(typeID: "public.png", kindName: "PNG", app: app) { finished.resume(returning: $0) }
        }
    }

    private func makeCoordinator() -> FileOpsCoordinator {
        FileOpsCoordinator(kernel: OperationKernel(), grid: PaneGridController(initialDirectory: URL(fileURLWithPath: "/")))
    }

    @Test func undoAndRedoGoThroughTheRegistry() async throws {
        let dir = try FaultFixture.tempDir("hspace-apps")
        defer { FaultFixture.remove(dir) }
        let old = dir.appendingPathComponent("Old.app")
        let new = dir.appendingPathComponent("New.app")
        try FaultFixture.write(to: old)
        try FaultFixture.write(to: new)
        let registry = MemoryRegistry(["public.png": old])
        let coordinator = makeCoordinator()
        coordinator.defaultAppRegistry = registry
        let undo = coordinator.undoManager
        undo.groupsByEvent = false

        undo.beginUndoGrouping()
        let change = await changed(coordinator, to: new)
        undo.endUndoGrouping()
        #expect(change?.previous == old)
        #expect(registry.defaultApp(for: .png) == new)

        undo.undo()
        await eventually("undone") { registry.defaultApp(for: .png) == old }
        undo.redo()
        await eventually("redone") { registry.defaultApp(for: .png) == new }
    }

    @Test func nothingToGoBackToOffersNoUndo() async throws {
        let dir = try FaultFixture.tempDir("hspace-apps")
        defer { FaultFixture.remove(dir) }
        let new = dir.appendingPathComponent("New.app")
        try FaultFixture.write(to: new)
        let coordinator = makeCoordinator()
        coordinator.defaultAppRegistry = MemoryRegistry()
        coordinator.undoManager.groupsByEvent = false
        coordinator.undoManager.beginUndoGrouping()
        let change = await changed(coordinator, to: new)
        coordinator.undoManager.endUndoGrouping()
        #expect(change?.previous == nil)
        #expect(coordinator.undoManager.undoActionName.isEmpty)
    }

    @Test func aFailureGivesNoChangeAndNoUndo() async throws {
        let dir = try FaultFixture.tempDir("hspace-apps")
        defer { FaultFixture.remove(dir) }
        let coordinator = makeCoordinator()
        coordinator.defaultAppRegistry = MemoryRegistry()
        coordinator.undoManager.groupsByEvent = false
        coordinator.undoManager.beginUndoGrouping()
        let change = await changed(coordinator, to: dir.appendingPathComponent("Gone.app"))
        coordinator.undoManager.endUndoGrouping()
        #expect(change == nil)
        #expect(coordinator.undoManager.undoActionName.isEmpty)
    }
}

@MainActor @Suite struct DefaultAppMenuTests {
    private func item(_ name: String, type: String?, directory: Bool = false) -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/x/\(name)"), name: name, isDirectory: directory, isPackage: false,
                 isSymlink: false, isHidden: false, size: nil, modified: nil, created: nil, contentTypeID: type)
    }

    @Test func offeredOnlyForFilesOfAChangeableKind() {
        #expect(MetadataMenu.defaultAppKind(of: item("a.png", type: "public.png")) == "public.png")
        #expect(MetadataMenu.defaultAppKind(of: item("a", type: "public.folder", directory: true)) == nil)
        #expect(MetadataMenu.defaultAppKind(of: item("a", type: nil)) == nil)
        #expect(MetadataMenu.defaultAppKind(of: item("a.xyz", type: "dyn.ah62d4rv4ge8")) == nil)
    }
}
