import Foundation

/// Sole Commit Owner of the launcher's command history. Synchronous on purpose: every keystroke asks for it on the main actor.
/// The file is read once. Storage directory is constructor-injected (Axiom 2).
public final class CommandHistoryStore: CommandHistoryStoring, @unchecked Sendable {
    private let fileURL: URL
    private let capacity: Int
    private let lock = NSLock()
    private var ids: [String] = []
    private var unusableFileReason: String?
    private var problem: LauncherError?

    public init(directory: URL, capacity: Int = 32) {
        fileURL = directory.appendingPathComponent("launcher-history.json")
        self.capacity = capacity
        load()
    }

    public func recent() -> [String] { locked { ids } }

    public func takeProblem() -> LauncherError? {
        locked {
            defer { problem = nil }
            return problem
        }
    }

    /// Memory changes only once the file has
    public func record(_ id: String) throws {
        try locked {
            let next = Array(([id] + ids.filter { $0 != id }).prefix(capacity))
            guard next != ids else { return }
            try persist(next)
            ids = next
        }
    }

    // MARK: Private

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func load() {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            return
        } catch {
            setAside(because: error.localizedDescription)
            return
        }
        do {
            ids = try JSONDecoder().decode([String].self, from: data)
        } catch {
            setAside(because: "the file is damaged")
        }
    }

    /// Moves a file that cannot be loaded out of the way, so no later write replaces it.
    /// While it stays in place, nothing may be written: the next write retries.
    @discardableResult
    private func setAside(because reason: String? = nil) -> LauncherError? {
        guard let reason = reason ?? unusableFileReason else { return nil }
        unusableFileReason = reason
        let kept = fileURL.appendingPathExtension("corrupt-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: fileURL, to: kept)
        } catch {
            let failure = LauncherError(.external, "The launcher history could not be read (\(reason)) and the file could not be moved aside, so it will not be saved: \(error.localizedDescription)")
            problem = failure
            return failure
        }
        unusableFileReason = nil
        problem = LauncherError(.external, "The launcher history could not be read (\(reason)). The file was kept at \(kept.path).")
        return nil
    }

    private func persist(_ next: [String]) throws {
        if let blocked = setAside() { throw blocked }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: fileURL, options: .atomic)
        } catch {
            throw LauncherError(.external, "Could not save the launcher history: \(error.localizedDescription)")
        }
    }
}
