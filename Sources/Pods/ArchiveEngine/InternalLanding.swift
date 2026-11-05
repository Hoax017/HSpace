import Foundation
import HSpaceContracts

// Private concern: moves extracted items from the staging directory to the target directory.
// Nothing that already exists is removed without a decision from the conflict panel. With no decision, both are kept.
// Everything here is a rename inside one volume, because staging lives in the target directory.

extension ArchiveEngineNode {

    /// Lands `items` in `target`, asking about every name that is already taken. Returns what landed at the top level.
    /// `stagingAlive` turns false if staging has to outlive the operation because it holds the only copy of an old item.
    func land(_ items: [URL], in target: URL, staging: URL, context: NodeContext,
              stagingAlive: inout Bool) async throws -> [URL] {
        var conflicts: [FileConflict] = []
        for item in items {
            let dest = target.appendingPathComponent(item.lastPathComponent)
            guard Self.itemExists(dest) else { continue }
            conflicts.append(FileConflict(source: item, existing: dest,
                                          bothDirectories: Self.isDirectory(item) && Self.isDirectory(dest)))
        }
        var decisions: [URL: ConflictDecision] = [:]
        if !conflicts.isEmpty {
            guard let answer = await context.resolveConflicts(conflicts) else {
                throw CancellationError()   // cancelled in the panel: nothing has landed yet
            }
            decisions = answer
        }

        var landed: [URL] = []
        for item in items {
            let dest = target.appendingPathComponent(item.lastPathComponent)
            guard Self.itemExists(dest) else {
                try Self.move(item, to: dest)
                landed.append(dest)
                continue
            }
            switch decisions[item] ?? .keepBoth {
            case .skip:
                break   // stays in staging and goes away with it
            case .replace:
                try Self.replace(dest, with: item, staging: staging, stagingAlive: &stagingAlive)
                landed.append(dest)
            case .mergeFolders where Self.isDirectory(item) && Self.isDirectory(dest):
                try Self.merge(item, into: dest, staging: staging, stagingAlive: &stagingAlive)
                landed.append(dest)
            case .mergeFolders, .keepBoth:
                landed.append(try Self.moveKeepingBoth(item, as: item.lastPathComponent, in: target))
            case .rename(let name):
                // Only the last component counts, so a name cannot leave the target directory
                let component = URL(fileURLWithPath: name).lastPathComponent
                let usable = !["", ".", "..", "/"].contains(component)
                landed.append(try Self.moveKeepingBoth(item, as: usable ? component : item.lastPathComponent,
                                                       in: target))
            }
        }
        return landed
    }

    /// Same meaning as Merge in Transfer: a file replaces a file, folders merge, other items stay.
    /// A file and a folder with the same name are not interchangeable, so both are kept.
    private static func merge(_ folder: URL, into existing: URL, staging: URL, stagingAlive: inout Bool) throws {
        for item in try contents(of: folder) {
            let dest = existing.appendingPathComponent(item.lastPathComponent)
            guard itemExists(dest) else {
                try move(item, to: dest)
                continue
            }
            switch (isDirectory(item), isDirectory(dest)) {
            case (true, true):
                try merge(item, into: dest, staging: staging, stagingAlive: &stagingAlive)
            case (false, false):
                try replace(dest, with: item, staging: staging, stagingAlive: &stagingAlive)
            default:
                _ = try moveKeepingBoth(item, as: item.lastPathComponent, in: existing)
            }
        }
    }

    /// Replaces `dest` with `item`. The old item is parked in staging, not deleted, until the new one is in place.
    private static func replace(_ dest: URL, with item: URL, staging: URL, stagingAlive: inout Bool) throws {
        let fm = FileManager.default
        let parked = staging.appendingPathComponent(".replaced-\(UUID().uuidString)")
        try move(dest, to: parked)
        do {
            try fm.moveItem(at: item, to: dest)
        } catch {
            do {
                try fm.moveItem(at: parked, to: dest)
            } catch {
                stagingAlive = false
                throw ArchiveError(.external, "Could not restore \(dest.lastPathComponent). It is kept at \(parked.path)",
                                   path: parked.path)
            }
            throw ArchiveError(.external, "Could not replace \(dest.lastPathComponent): \(error.localizedDescription)",
                               path: dest.path)
        }
    }

    private static func moveKeepingBoth(_ item: URL, as name: String, in directory: URL) throws -> URL {
        let wanted = URL(fileURLWithPath: name)
        let free = uniqueArchiveName(base: wanted.deletingPathExtension().lastPathComponent, ext: wanted.pathExtension,
                                     in: directory, exists: itemExists)
        let dest = directory.appendingPathComponent(free)
        try move(item, to: dest)
        return dest
    }

    /// Fails instead of overwriting if the name was taken in the meantime.
    static func move(_ item: URL, to dest: URL) throws {
        do {
            try FileManager.default.moveItem(at: item, to: dest)
        } catch {
            throw ArchiveError(.external, "Could not move \(item.lastPathComponent): \(error.localizedDescription)",
                               path: dest.path)
        }
    }

    static func contents(of directory: URL) throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch {
            throw ArchiveError(.external, "Could not read \(directory.lastPathComponent): \(error.localizedDescription)",
                               path: directory.path)
        }
    }

    /// True for any item with this name, including a dangling symlink, which `fileExists` does not see.
    static func itemExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// True only for a real directory. A symlink to a directory is not one, so nothing lands through it.
    private static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }
}
