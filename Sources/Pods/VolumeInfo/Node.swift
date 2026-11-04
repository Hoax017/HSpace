import AppKit
import NSpaceContracts

/// Volume info node (Axiom 2: no global mutable state; NSWorkspace/FileManager are the controlled physical substrate)
public struct VolumeInfo: Sendable {
    public init() {}

    /// Enumerates currently mounted volumes (browsable ones; skips hidden system volumes)
    public func volumes() -> [VolumeItem] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsRootFileSystemKey,
            .volumeIsBrowsableKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let rv = try? url.resourceValues(forKeys: Set(keys)),
                  rv.volumeIsBrowsable ?? true else { return nil }
            return VolumeItem(
                name: rv.volumeName ?? url.lastPathComponent,
                url: url,
                totalCapacity: Int64(rv.volumeTotalCapacity ?? 0),
                availableCapacity: rv.volumeAvailableCapacityForImportantUsage ?? 0,
                isEjectable: rv.volumeIsEjectable ?? false,
                isRemovable: rv.volumeIsRemovable ?? false,
                isRoot: rv.volumeIsRootFileSystem ?? (url.path == "/"))
        }
    }

    /// Mount/unmount change signal stream (NSWorkspace notifications arrive on the main thread; stream termination removes observers automatically)
    @MainActor
    public func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let center = NSWorkspace.shared.notificationCenter
            let names: [Notification.Name] = [
                NSWorkspace.didMountNotification,
                NSWorkspace.didUnmountNotification,
                NSWorkspace.didRenameVolumeNotification,
            ]
            // Observer tokens are non-Sendable; a box carries them into the @Sendable onTermination
            let box = ObserverBox(center: center, tokens: names.map { name in
                center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    continuation.yield(())
                }
            })
            continuation.onTermination = { _ in box.removeAll() }
        }
    }

    /// Ejects a volume (failures are external: device busy, permissions and other outside conditions)
    public func eject(_ url: URL) throws {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: url)
        } catch {
            throw VolumeError(.external, error.localizedDescription)
        }
    }
}
