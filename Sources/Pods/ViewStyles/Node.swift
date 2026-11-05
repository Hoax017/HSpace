import Foundation
import HSpaceContracts

/// Sole Commit Owner of view rules. Synchronous on purpose: navigation asks on the main actor and must not wait.
/// The file is read once, so asking never touches the disk. Storage directory is constructor-injected (Axiom 2).
public final class ViewStyleStore: ViewStyleStoring, @unchecked Sendable {
    private struct Contents: Codable, Equatable {
        var folders: [String: FolderViewRule] = [:]
        var styles: [SavedViewStyle] = []
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var contents = Contents()
    private var unusableFileReason: String?
    private var problem: ViewStyleError?

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("view-styles.json")
        load()
    }

    // MARK: Queries

    public func rule(for path: String) -> ResolvedViewRule? {
        let start = Self.normalized(path)
        return locked {
            if let own = contents.folders[start] {
                return ResolvedViewRule(rule: own, folder: start, isExact: true)
            }
            var parent = start
            while parent != "/", !parent.isEmpty {
                parent = (parent as NSString).deletingLastPathComponent
                if let inherited = contents.folders[parent], inherited.includeSubfolders {
                    return ResolvedViewRule(rule: inherited, folder: parent, isExact: false)
                }
            }
            return nil
        }
    }

    public func folders() -> [String: FolderViewRule] { locked { contents.folders } }

    public func styles() -> [SavedViewStyle] { locked { contents.styles } }

    public func takeProblem() -> ViewStyleError? {
        locked {
            defer { problem = nil }
            return problem
        }
    }

    // MARK: Mutations: memory changes only once the file has

    public func setRule(_ rule: FolderViewRule, for path: String) throws {
        let key = Self.normalized(path)
        try commit { $0.folders[key] = rule }
    }

    public func removeRule(for path: String) throws {
        let key = Self.normalized(path)
        try commit { $0.folders[key] = nil }
    }

    @discardableResult
    public func saveStyle(named name: String, style: ViewStyle) throws -> SavedViewStyle {
        let title = try Self.usable(name)
        let saved = SavedViewStyle(id: UUID(), name: title, style: style)
        try commit { contents in
            try Self.refuseTaken(title, in: contents.styles, except: nil)
            contents.styles.append(saved)
        }
        return saved
    }

    public func renameStyle(_ id: UUID, to name: String) throws {
        let title = try Self.usable(name)
        try commit { contents in
            guard let index = contents.styles.firstIndex(where: { $0.id == id }) else {
                throw ViewStyleError(.logic, "That style no longer exists.")
            }
            try Self.refuseTaken(title, in: contents.styles, except: id)
            contents.styles[index].name = title
        }
    }

    public func deleteStyle(_ id: UUID) throws {
        try commit { $0.styles.removeAll { $0.id == id } }
    }

    // MARK: Private

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func commit(_ change: (inout Contents) throws -> Void) throws {
        try locked {
            var next = contents
            try change(&next)
            guard next != contents else { return }
            try persist(next)
            contents = next
        }
    }

    private static func normalized(_ path: String) -> String {
        let clean = URL(fileURLWithPath: path).standardizedFileURL.path
        return clean.count > 1 && clean.hasSuffix("/") ? String(clean.dropLast()) : clean
    }

    private static func usable(_ name: String) throws -> String {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ViewStyleError(.logic, "A style needs a name.") }
        return title
    }

    private static func refuseTaken(_ name: String, in styles: [SavedViewStyle], except id: UUID?) throws {
        let taken = styles.contains { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }
        if taken { throw ViewStyleError(.logic, "There is already a style named \"\(name)\".") }
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
            contents = try JSONDecoder().decode(Contents.self, from: data)
        } catch {
            setAside(because: "the file is damaged")
        }
    }

    /// Moves a file that cannot be loaded out of the way, so no later write replaces it.
    /// While it stays in place, nothing may be written: the next write retries.
    @discardableResult
    private func setAside(because reason: String? = nil) -> ViewStyleError? {
        guard let reason = reason ?? unusableFileReason else { return nil }
        unusableFileReason = reason
        let kept = fileURL.appendingPathExtension("corrupt-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: fileURL, to: kept)
        } catch {
            let failure = ViewStyleError(.external, "View styles could not be read (\(reason)) and the file could not be moved aside, so changes will not be saved: \(error.localizedDescription)")
            problem = failure
            return failure
        }
        unusableFileReason = nil
        problem = ViewStyleError(.external, "View styles could not be read (\(reason)). The file was kept at \(kept.path).")
        return nil
    }

    private func persist(_ next: Contents) throws {
        if let blocked = setAside() { throw blocked }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: fileURL, options: .atomic)
        } catch {
            throw ViewStyleError(.external, "Could not save view styles: \(error.localizedDescription)")
        }
    }
}
