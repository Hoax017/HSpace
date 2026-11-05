import Foundation
import HSpaceContracts

/// Sole Commit Owner of the history (actor serial commits + atomic persistence). Directory is constructor-injected (Axiom 2).
public actor HistoryStore {
    private struct Contents: Codable {
        var entries: [HistoryEntry] = []
        var undoneGroups: Set<UUID> = []
    }

    private let fileURL: URL
    private let limit: Int
    private var contents = Contents()
    private var loaded = false
    /// Why the file could not be loaded, while it still sits there: it must be moved aside before any write
    private var unusableFileReason: String?
    private var problem: HistoryError?

    /// `limit` counts entries. Whole oldest groups go first, so that a group is never left half remembered.
    public init(directory: URL, limit: Int = 1000) {
        fileURL = directory.appendingPathComponent("operation-history.json")
        self.limit = limit
    }

    /// Newest first
    public func groups() -> [HistoryGroup] {
        ensureLoaded()
        var order: [UUID] = []
        var members: [UUID: [HistoryEntry]] = [:]
        for entry in contents.entries {
            if members[entry.groupID] == nil { order.append(entry.groupID) }
            members[entry.groupID, default: []].append(entry)
        }
        return order.reversed().map { id in
            HistoryGroup(id: id, entries: members[id] ?? [], isUndone: contents.undoneGroups.contains(id))
        }
    }

    public func group(_ id: UUID) -> HistoryGroup? {
        groups().first { $0.id == id }
    }

    public func record(_ entry: HistoryEntry) {
        ensureLoaded()
        contents.entries.append(entry)
        trim()
        persist()
    }

    public func markUndone(_ group: UUID) {
        ensureLoaded()
        contents.undoneGroups.insert(group)
        persist()
    }

    /// Forgets everything. Touches no file but the history's own.
    public func clear() {
        ensureLoaded()
        contents = Contents()
        persist()
    }

    /// Hands over the last unreported failure once
    public func takeProblem() -> HistoryError? {
        ensureLoaded()
        defer { problem = nil }
        return problem
    }

    private func trim() {
        while contents.entries.count > limit, let oldest = contents.entries.first?.groupID {
            // The newest group stays whatever its size: dropping it would forget the action just done
            guard oldest != contents.entries.last?.groupID else { return }
            contents.entries.removeAll { $0.groupID == oldest }
            contents.undoneGroups.remove(oldest)
        }
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            return
        } catch {
            unusableFileReason = error.localizedDescription
            setAsideUnusableFile()
            return
        }
        do {
            contents = try JSONDecoder().decode(Contents.self, from: data)
        } catch {
            unusableFileReason = "the file is damaged"
            setAsideUnusableFile()
        }
    }

    /// Moves an unreadable file to `<name>.corrupt-<UUID>` so that no later write replaces it. False while it stays in place.
    @discardableResult
    private func setAsideUnusableFile() -> Bool {
        guard let reason = unusableFileReason else { return true }
        let kept = fileURL.appendingPathExtension("corrupt-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: fileURL, to: kept)
        } catch {
            problem = HistoryError(.external, "The operation history could not be read (\(reason)) and the file could not be moved aside, so changes will not be saved: \(error.localizedDescription)")
            return false
        }
        unusableFileReason = nil
        problem = HistoryError(.external, "The operation history could not be read (\(reason)). The file was kept at \(kept.path).")
        return true
    }

    private func persist() {
        guard setAsideUnusableFile() else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(contents).write(to: fileURL, options: .atomic)
        } catch {
            problem = HistoryError(.external, "Could not save the operation history: \(error.localizedDescription)")
        }
    }
}
