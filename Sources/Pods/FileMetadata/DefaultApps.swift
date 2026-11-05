import AppKit
import UniformTypeIdentifiers
import HSpaceContracts

/// macOS's record of which app opens which kind of file. A protocol because the real one changes a system-wide setting,
/// which tests must never touch.
public protocol DefaultAppRegistry: Sendable {
    func defaultApp(for type: UTType) -> URL?
    func setDefaultApp(_ app: URL, for type: UTType) async throws
}

public struct SystemDefaultApps: DefaultAppRegistry {
    public init() {}

    public func defaultApp(for type: UTType) -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: type)
    }

    public func setDefaultApp(_ app: URL, for type: UTType) async throws {
        try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type)
    }
}

/// A change that was made, with what it takes to go back
public struct DefaultAppChange: Sendable, Hashable {
    public let typeID: String
    public let app: URL
    /// nil when no app was set before, which cannot be restored
    public let previous: URL?

    public init(typeID: String, app: URL, previous: URL?) {
        self.typeID = typeID
        self.app = app
        self.previous = previous
    }
}

public struct DefaultApps: Sendable {
    private let registry: any DefaultAppRegistry

    public init(registry: any DefaultAppRegistry) {
        self.registry = registry
    }

    /// Kinds that can have their own default. Not folders, which macOS keeps for Finder, nor types that only say "some
    /// data", where the change would reach nearly every file, nor `dyn.` types, which exist only for one unknown extension.
    public static func canChange(typeID: String?) -> Bool {
        guard let typeID, !typeID.hasPrefix("dyn."), let type = UTType(typeID) else { return false }
        return ![UTType.folder, .directory, .item, .data, .content, .package, .application].contains(type)
    }

    public func currentApp(typeID: String) -> URL? {
        UTType(typeID).flatMap { registry.defaultApp(for: $0) }
    }

    /// Makes `app` the default, and checks that macOS really took it.
    public func change(typeID: String, to app: URL) async throws -> DefaultAppChange {
        guard Self.canChange(typeID: typeID), let type = UTType(typeID) else {
            throw MetadataError(.logic, "This kind of file cannot have its own default app")
        }
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw MetadataError(.external, "\"\(app.lastPathComponent)\" is no longer there")
        }
        let previous = registry.defaultApp(for: type)
        do {
            try await registry.setDefaultApp(app, for: type)
        } catch let error as MetadataError {
            throw error
        } catch {
            throw MetadataError(.external, "macOS refused the change: \(error.localizedDescription)")
        }
        guard registry.defaultApp(for: type)?.standardizedFileURL == app.standardizedFileURL else {
            throw MetadataError(.external, "macOS kept the old default app")
        }
        return DefaultAppChange(typeID: typeID, app: app, previous: previous)
    }
}
