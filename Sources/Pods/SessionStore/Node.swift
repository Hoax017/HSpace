import Foundation
import HSpaceContracts

/// Sole Commit Owner of authoritative session state (actor): 1s debounced atomic persistence of session.json (spec section 5, data contract).
/// Storage directory is constructor-injected (Axiom 2).
public actor SessionStore {
    private let fileURL: URL
    private var pendingSaveTask: Task<Void, Never>?
    private var latest: SessionSnapshot?

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("session.json")
    }

    /// Startup restore: returns nil when missing or corrupt (falls back to the default layout; fault matrix: no crash, no alert)
    public func load() -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }

    /// Call on every state change: 1s debounce coalesces (rapid tab switching does not cause a write storm)
    public func save(_ snapshot: SessionSnapshot) {
        latest = snapshot
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    /// Forces persistence before quit (skips the debounce)
    public func flush() {
        guard let snapshot = latest else { return }
        pendingSaveTask?.cancel()
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // On persistence failure keep in-memory state; the next debounced save retries (fault matrix)
        }
    }
}
