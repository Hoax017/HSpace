import Foundation
import HSpaceContracts

/// Sole Commit Owner of authoritative session state (actor): 1s debounced atomic persistence of session.json (spec section 5, data contract).
/// Storage directory is constructor-injected (Axiom 2).
public actor SessionStore {
    private let fileURL: URL
    private var pendingSaveTask: Task<Void, Never>?
    private var latest: SessionSnapshot?
    /// Whether the file on disk has been looked at: a write must never come before that
    private var fileChecked = false
    /// Why the file at fileURL could not be loaded, while it still sits there: it must be moved aside before any write
    private var unusableFileReason: String?
    /// Failure no call could throw to its caller, waiting for takeProblem()
    private var problem: SessionError?

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("session.json")
    }

    /// Hands over the last unreported failure once, for the app to show (for example a file that was kept aside at load).
    public func takeProblem() -> SessionError? {
        if !fileChecked { _ = load() }
        defer { problem = nil }
        return problem
    }

    /// Startup restore: returns nil when missing or corrupt (falls back to the default layout; fault matrix: no crash, no alert).
    /// A corrupt file is kept aside and reported through takeProblem().
    public func load() -> SessionSnapshot? {
        fileChecked = true
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            setAsideUnusableFile(because: error.localizedDescription)
            return nil
        }
        do {
            return try JSONDecoder().decode(SessionSnapshot.self, from: data)
        } catch {
            setAsideUnusableFile(because: "the file is damaged")
            return nil
        }
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
        if !fileChecked { _ = load() }
        guard setAsideUnusableFile() == nil else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // On persistence failure keep in-memory state; the next debounced save retries (fault matrix)
        }
    }

    /// Moves a file that cannot be loaded to `<name>.corrupt-<UUID>` so that no later write replaces it.
    /// Returns the error while the file stays in place: nothing may be written then, and the next write retries.
    @discardableResult
    private func setAsideUnusableFile(because reason: String? = nil) -> SessionError? {
        guard let reason = reason ?? unusableFileReason else { return nil }
        unusableFileReason = reason
        let kept = fileURL.appendingPathExtension("corrupt-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: fileURL, to: kept)
        } catch {
            let failure = SessionError(.external, "The saved session could not be read (\(reason)) and the file could not be moved aside, so changes will not be saved: \(error.localizedDescription)")
            problem = failure
            return failure
        }
        unusableFileReason = nil
        problem = SessionError(.external, "The saved session could not be read (\(reason)). The file was kept at \(kept.path).")
        return nil
    }
}
