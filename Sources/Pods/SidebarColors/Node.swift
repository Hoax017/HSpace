import Foundation

/// Sole Commit Owner of sidebar colours. Synchronous on purpose: the sidebar asks while it builds its rows.
/// The file is read once. Storage directory is constructor-injected (Axiom 2).
public final class SidebarColorStore: SidebarColorStoring, @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var contents = SidebarColorSettings()
    private var unusableFileReason: String?
    private var problem: SidebarColorError?

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("sidebar-colors.json")
        load()
    }

    public func settings() -> SidebarColorSettings { locked { contents } }

    public func takeProblem() -> SidebarColorError? {
        locked {
            defer { problem = nil }
            return problem
        }
    }

    public func setColor(_ color: SidebarColor?, for key: String) throws {
        try commit { $0.items[key] = color }
    }

    public func setPalette(_ palette: SidebarPalette) throws {
        try commit { $0.palette = palette }
    }

    // MARK: Private

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Memory changes only once the file has
    private func commit(_ change: (inout SidebarColorSettings) -> Void) throws {
        try locked {
            var next = contents
            change(&next)
            guard next != contents else { return }
            try persist(next)
            contents = next
        }
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
            contents = try JSONDecoder().decode(SidebarColorSettings.self, from: data)
        } catch {
            setAside(because: "the file is damaged")
        }
    }

    /// Moves a file that cannot be loaded out of the way, so no later write replaces it.
    /// While it stays in place, nothing may be written: the next write retries.
    @discardableResult
    private func setAside(because reason: String? = nil) -> SidebarColorError? {
        guard let reason = reason ?? unusableFileReason else { return nil }
        unusableFileReason = reason
        let kept = fileURL.appendingPathExtension("corrupt-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: fileURL, to: kept)
        } catch {
            let failure = SidebarColorError(.external, "Sidebar colours could not be read (\(reason)) and the file could not be moved aside, so changes will not be saved: \(error.localizedDescription)")
            problem = failure
            return failure
        }
        unusableFileReason = nil
        problem = SidebarColorError(.external, "Sidebar colours could not be read (\(reason)). The file was kept at \(kept.path).")
        return nil
    }

    private func persist(_ next: SidebarColorSettings) throws {
        if let blocked = setAside() { throw blocked }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: fileURL, options: .atomic)
        } catch {
            throw SidebarColorError(.external, "Could not save sidebar colours: \(error.localizedDescription)")
        }
    }
}
