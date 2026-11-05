import Foundation
import HSpaceContracts

/// Sole Commit Owner of the metadata settings (BG-5). The directory is injected (Axiom 2).
public actor MetadataStore {
    private struct Contents: Codable {
        var colorRules: [ColorRule] = []
    }

    private let fileURL: URL
    private var contents = Contents()
    private var loaded = false
    /// Why the file could not be loaded, while it still sits there: it must be moved aside before any write
    private var unusableFileReason: String?
    /// Failure no call could throw to its caller, waiting for takeProblem()
    private var problem: MetadataError?

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("file-metadata.json")
    }

    public func colorRules() -> [ColorRule] {
        ensureLoaded()
        return contents.colorRules
    }

    /// Nothing changes unless the new rules reach the disk.
    public func setColorRules(_ rules: [ColorRule]) throws {
        ensureLoaded()
        var updated = contents
        updated.colorRules = rules
        try persist(updated)
        contents = updated
    }

    /// Hands over the last unreported failure once, for the app to show.
    public func takeProblem() -> MetadataError? {
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
            setAsideUnusableFile(because: error.localizedDescription)
            return
        }
        do {
            contents = try JSONDecoder().decode(Contents.self, from: data)
        } catch {
            setAsideUnusableFile(because: "the file is damaged")
        }
    }

    /// Moves a file that cannot be loaded to `<name>.corrupt-<UUID>`, so that no later write replaces it.
    /// Returns the error while the file stays in place: nothing may be written then, and the next write retries.
    @discardableResult
    private func setAsideUnusableFile(because reason: String? = nil) -> MetadataError? {
        guard let reason = reason ?? unusableFileReason else { return nil }
        unusableFileReason = reason
        let kept = fileURL.appendingPathExtension("corrupt-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: fileURL, to: kept)
        } catch {
            let failure = MetadataError(.external, "The file colour settings could not be read (\(reason)) and the file could not be moved aside, so changes will not be saved: \(error.localizedDescription)")
            problem = failure
            return failure
        }
        unusableFileReason = nil
        problem = MetadataError(.external, "The file colour settings could not be read (\(reason)). The file was kept at \(kept.path).")
        return nil
    }

    private func persist(_ contents: Contents) throws {
        if let blocked = setAsideUnusableFile() { throw blocked }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(contents).write(to: fileURL, options: .atomic)
        } catch {
            throw MetadataError(.external, "Could not save the file colour settings: \(error.localizedDescription)")
        }
    }
}
