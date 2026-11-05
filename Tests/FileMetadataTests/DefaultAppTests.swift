import Foundation
import FileMetadata
import HSpaceTestSupport
import Testing
import UniformTypeIdentifiers

/// Stands in for LaunchServices: the real one is a system-wide setting
final class FakeRegistry: DefaultAppRegistry, @unchecked Sendable {
    private let lock = NSLock()
    private var apps: [String: URL] = [:]
    var refusal: (any Error)?
    /// macOS can answer success and keep the old app
    var ignoresChanges = false

    func defaultApp(for type: UTType) -> URL? {
        lock.withLock { apps[type.identifier] }
    }

    func setDefaultApp(_ app: URL, for type: UTType) async throws {
        if let refusal { throw refusal }
        guard !ignoresChanges else { return }
        lock.withLock { apps[type.identifier] = app }
    }
}

@Suite struct DefaultAppTests {
    private func app(in dir: URL, _ name: String = "Viewer.app") throws -> URL {
        let url = dir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func ordinaryKindsCanChange() {
        #expect(DefaultApps.canChange(typeID: "public.png"))
        #expect(DefaultApps.canChange(typeID: "com.adobe.pdf"))
    }

    @Test func kindsThatMustNotChangeAreRefused() {
        for typeID in ["public.folder", "public.directory", "public.data", "public.item", "public.content",
                       "com.apple.package", "com.apple.application", "dyn.ah62d4rv4ge8", "not a type", ""] {
            #expect(!DefaultApps.canChange(typeID: typeID), "\(typeID)")
        }
        #expect(!DefaultApps.canChange(typeID: nil))
    }

    @Test func aChangeRemembersThePreviousApp() async throws {
        let dir = try FaultFixture.tempDir("hspace-apps")
        defer { FaultFixture.remove(dir) }
        let first = try app(in: dir, "First.app")
        let second = try app(in: dir, "Second.app")
        let registry = FakeRegistry()
        let apps = DefaultApps(registry: registry)

        let initial = try await apps.change(typeID: "public.png", to: first)
        #expect(initial.previous == nil)

        let change = try await apps.change(typeID: "public.png", to: second)
        #expect(change.previous == first)
        #expect(apps.currentApp(typeID: "public.png") == second)
    }

    @Test func aRefusedKindNeverReachesTheSystem() async throws {
        let dir = try FaultFixture.tempDir("hspace-apps")
        defer { FaultFixture.remove(dir) }
        let registry = FakeRegistry()
        let viewer = try app(in: dir)
        await #expect(throws: MetadataError.self) {
            try await DefaultApps(registry: registry).change(typeID: "public.folder", to: viewer)
        }
        #expect(registry.defaultApp(for: .folder) == nil)
    }

    @Test func aMissingAppIsRefused() async throws {
        let dir = try FaultFixture.tempDir("hspace-apps")
        defer { FaultFixture.remove(dir) }
        await #expect(throws: MetadataError.self) {
            try await DefaultApps(registry: FakeRegistry()).change(typeID: "public.png",
                                                                   to: dir.appendingPathComponent("Gone.app"))
        }
    }

    @Test func aSystemRefusalIsClassified() async throws {
        let dir = try FaultFixture.tempDir("hspace-apps")
        defer { FaultFixture.remove(dir) }
        let registry = FakeRegistry()
        registry.refusal = POSIXError(.EPERM)
        let viewer = try app(in: dir)
        await #expect {
            try await DefaultApps(registry: registry).change(typeID: "public.png", to: viewer)
        } throws: { error in
            (error as? MetadataError)?.errorClass == .external
        }
    }

    @Test func aChangeMacOSIgnoredIsAFailure() async throws {
        let dir = try FaultFixture.tempDir("hspace-apps")
        defer { FaultFixture.remove(dir) }
        let registry = FakeRegistry()
        registry.ignoresChanges = true
        let viewer = try app(in: dir)
        await #expect(throws: MetadataError.self) {
            try await DefaultApps(registry: registry).change(typeID: "public.png", to: viewer)
        }
    }
}
