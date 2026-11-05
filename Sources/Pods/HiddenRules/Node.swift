import Foundation
import HSpaceContracts

/// Sole Commit Owner of the rules. Synchronous on purpose: every listing asks, on the main actor.
/// The file is read once. Storage directory is constructor-injected (Axiom 2).
public final class HiddenRuleStore: HiddenRuleStoring, @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var current: [HiddenRule] = []
    private var unusableFileReason: String?
    private var problem: HiddenRuleError?

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("hidden-rules.json")
        load()
    }

    public func rules() -> [HiddenRule] {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    public func takeProblem() -> HiddenRuleError? {
        lock.lock()
        defer { lock.unlock() }
        defer { problem = nil }
        return problem
    }

    public func save(_ rules: [HiddenRule]) throws {
        guard !rules.contains(where: { $0.pattern.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw HiddenRuleError(.logic, "A rule needs a pattern.")
        }
        lock.lock()
        defer { lock.unlock() }
        if let blocked = setAside() { throw blocked }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(rules).write(to: fileURL, options: .atomic)
        } catch {
            throw HiddenRuleError(.external, "Could not save the hidden item rules: \(error.localizedDescription)")
        }
        current = rules
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
            current = try JSONDecoder().decode([HiddenRule].self, from: data)
        } catch {
            setAside(because: "the file is damaged")
        }
    }

    /// Moves a file that cannot be loaded out of the way, so no later write replaces it.
    /// While it stays in place, nothing may be written: the next write retries.
    @discardableResult
    private func setAside(because reason: String? = nil) -> HiddenRuleError? {
        guard let reason = reason ?? unusableFileReason else { return nil }
        unusableFileReason = reason
        let kept = fileURL.appendingPathExtension("corrupt-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: fileURL, to: kept)
        } catch {
            let failure = HiddenRuleError(.external, "The hidden item rules could not be read (\(reason)) and the file could not be moved aside, so changes will not be saved: \(error.localizedDescription)")
            problem = failure
            return failure
        }
        unusableFileReason = nil
        problem = HiddenRuleError(.external, "The hidden item rules could not be read (\(reason)). The file was kept at \(kept.path).")
        return nil
    }
}
