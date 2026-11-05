import Foundation
import HSpaceContracts

public struct RenamePreset: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let name: String
    public let steps: [RenameStep]

    public init(id: UUID = UUID(), name: String, steps: [RenameStep]) {
        self.id = id; self.name = name; self.steps = steps
    }
}

/// One finished batch. An undo is a batch too, so the log tells the true order of events.
public struct RenameLogEntry: Sendable, Hashable, Codable, Identifiable {
    public let journal: RenameJournal
    /// The entry this batch reversed
    public let reverses: UUID?
    /// A later batch reversed this one, so it can no longer be undone from the log
    public var isReversed: Bool

    public var id: UUID { journal.id }
}

/// Sole owner of saved presets and the rename log. The directory is constructor-injected (Axiom 2).
/// A file that cannot be read is kept aside and reported, never overwritten.
public actor RenameStore {
    public static let logLimit = 200

    private var presetFile: JSONFile<[RenamePreset]>
    private var logFile: JSONFile<[RenameLogEntry]>
    private var problem: BatchRenameError?

    public init(directory: URL) {
        presetFile = JSONFile(url: directory.appendingPathComponent("rename-presets.json"), label: "rename presets", empty: [])
        logFile = JSONFile(url: directory.appendingPathComponent("rename-log.json"), label: "rename log", empty: [])
    }

    /// Hands over the last unreported failure once.
    public func takeProblem() -> BatchRenameError? {
        presetFile.load()
        logFile.load()
        defer { problem = nil; presetFile.problem = nil; logFile.problem = nil }
        return problem ?? presetFile.problem ?? logFile.problem
    }

    public func presets() -> [RenamePreset] {
        presetFile.load()
        return presetFile.value
    }

    /// A preset of the same name is replaced.
    public func savePreset(named name: String, steps: [RenameStep]) throws {
        presetFile.load()
        var presets = presetFile.value.filter { $0.name != name }
        presets.append(RenamePreset(name: name, steps: steps))
        presets.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        try presetFile.save(presets)
    }

    public func deletePreset(id: UUID) throws {
        presetFile.load()
        try presetFile.save(presetFile.value.filter { $0.id != id })
    }

    /// Newest first.
    public func log() -> [RenameLogEntry] {
        logFile.load()
        return logFile.value
    }

    /// Never throws: the rename has already happened, so a failed save is only something to report.
    public func record(_ journal: RenameJournal, reverses: UUID? = nil) {
        logFile.load()
        var entries = logFile.value
        if let reverses, let index = entries.firstIndex(where: { $0.id == reverses }) {
            entries[index].isReversed = true
        }
        entries.insert(RenameLogEntry(journal: journal, reverses: reverses, isReversed: false), at: 0)
        do {
            try logFile.save(Array(entries.prefix(Self.logLimit)))
        } catch let failure as BatchRenameError {
            problem = failure
        } catch {
            problem = BatchRenameError(.external, error.localizedDescription)
        }
    }
}

/// One JSON document on disk: kept aside when unreadable, replaced atomically on save.
private struct JSONFile<Value: Codable & Sendable>: Sendable {
    let url: URL
    let label: String
    var value: Value
    var problem: BatchRenameError?
    private var loaded = false
    /// The damaged file is still at `url`: it must move before anything is written
    private var unusableReason: String?

    init(url: URL, label: String, empty: Value) {
        self.url = url; self.label = label; value = empty
    }

    mutating func load() {
        guard !loaded else { return }
        loaded = true
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return
        } catch {
            problem = setAside(because: error.localizedDescription) ?? problem
            return
        }
        do {
            value = try JSONDecoder().decode(Value.self, from: data)
        } catch {
            problem = setAside(because: "the file is damaged") ?? problem
        }
    }

    private mutating func setAside(because reason: String) -> BatchRenameError? {
        unusableReason = reason
        let kept = url.appendingPathExtension("corrupt-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: url, to: kept)
        } catch {
            return BatchRenameError(.external, "The \(label) could not be read (\(reason)) and the file could not be moved aside, so changes will not be saved: \(error.localizedDescription)")
        }
        unusableReason = nil
        problem = BatchRenameError(.external, "The \(label) could not be read (\(reason)). The file was kept at \(kept.path).")
        return nil
    }

    mutating func save(_ newValue: Value) throws {
        load()
        if let reason = unusableReason, let blocked = setAside(because: reason) { throw blocked }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(newValue).write(to: url, options: .atomic)
        } catch {
            throw BatchRenameError(.external, "Could not save the \(label): \(error.localizedDescription)")
        }
        value = newValue
    }
}
