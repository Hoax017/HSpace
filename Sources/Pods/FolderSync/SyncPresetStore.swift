import Foundation
import HSpaceContracts

/// Saved sync settings (actor serial commits + atomic persistence). Directory is constructor-injected (Axiom 2).
public actor SyncPresetStore {
    /// Ready-made settings, not stored: they are always there and cannot be damaged.
    public static let builtIn: [SyncPreset] = [
        SyncPreset(id: UUID(uuidString: "5B1E0D4A-0000-4000-8000-000000000001") ?? UUID(), name: "Backup",
                   options: SyncOptions(direction: .leftToRight)),
        SyncPreset(id: UUID(uuidString: "5B1E0D4A-0000-4000-8000-000000000002") ?? UUID(), name: "Mirror",
                   options: SyncOptions(direction: .leftToRight, deleteExtras: true)),
        SyncPreset(id: UUID(uuidString: "5B1E0D4A-0000-4000-8000-000000000003") ?? UUID(), name: "Two-way",
                   options: SyncOptions(direction: .twoWay)),
    ]

    private let fileURL: URL
    private var presets: [SyncPreset] = []
    private var loaded = false
    private var unusableFileReason: String?
    private var problem: SyncError?

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("sync-presets.json")
    }

    /// The user's presets, oldest first
    public func saved() -> [SyncPreset] {
        ensureLoaded()
        return presets
    }

    /// Adds a preset, or replaces the one with the same name.
    public func save(_ preset: SyncPreset) {
        ensureLoaded()
        presets.removeAll { $0.name.caseInsensitiveCompare(preset.name) == .orderedSame }
        presets.append(preset)
        persist()
    }

    public func remove(_ id: UUID) {
        ensureLoaded()
        presets.removeAll { $0.id == id }
        persist()
    }

    public func takeProblem() -> SyncError? {
        ensureLoaded()
        defer { problem = nil }
        return problem
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
            presets = try JSONDecoder().decode([SyncPreset].self, from: data)
        } catch {
            unusableFileReason = "the file is damaged"
            setAsideUnusableFile()
        }
    }

    /// Moves an unreadable file aside so that no later write replaces it. False while it stays in place.
    @discardableResult
    private func setAsideUnusableFile() -> Bool {
        guard let reason = unusableFileReason else { return true }
        let kept = fileURL.appendingPathExtension("corrupt-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: fileURL, to: kept)
        } catch {
            problem = SyncError(.external, "The sync presets could not be read (\(reason)) and the file could not be moved aside, so changes will not be saved: \(error.localizedDescription)")
            return false
        }
        unusableFileReason = nil
        problem = SyncError(.external, "The sync presets could not be read (\(reason)). The file was kept at \(kept.path).")
        return true
    }

    private func persist() {
        guard setAsideUnusableFile() else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(presets).write(to: fileURL, options: .atomic)
        } catch {
            problem = SyncError(.external, "Could not save the sync presets: \(error.localizedDescription)")
        }
    }
}
