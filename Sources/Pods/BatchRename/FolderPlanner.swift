import Darwin
import Foundation

/// What a merge or flatten will do: move `moves` into `target` (a plain move, so Transfer's conflict and merge rules apply),
/// after which each of `emptied` holds nothing worth keeping.
public struct FolderPlan: Sendable, Equatable {
    public let target: URL
    public let moves: [URL]
    public let emptied: [URL]
}

/// Reads folders and says what to move. It moves nothing: the transfer engine owns that.
/// A folder that cannot be read stops the plan: treating it as empty would send its contents to the Trash.
public enum FolderPlanner {
    /// Finder's own bookkeeping: never worth a conflict, and no reason to keep a folder
    private static let ignored: Set<String> = [".DS_Store"]

    /// Every item directly inside `folders` moves into `target`, which may be one of them and is then left out.
    public static func mergePlan(folders: [URL], into target: URL) throws -> FolderPlan {
        try requireFolder(target)
        let sources = folders.filter { !isSameItem($0, target) }
        var moves: [URL] = []
        for folder in sources {
            try requireFolder(folder)
            if isInside(target, folder: folder) {
                throw BatchRenameError(.external, "\(folder.lastPathComponent) holds \(target.lastPathComponent), so it cannot be merged into it.", path: folder.path)
            }
            moves += try children(of: folder)
        }
        return FolderPlan(target: target, moves: moves, emptied: sources)
    }

    /// Every file below the first level of `folder` moves up into it, then its subfolders are empty.
    /// A package counts as a file, and so does a hidden folder such as `.git`, which stops being one if it is taken apart.
    public static func flattenPlan(folder: URL) throws -> FolderPlan {
        try requireFolder(folder)
        var moves: [URL] = []
        var emptied: [URL] = []
        for child in try children(of: folder) where try isOpenFolder(child) {
            emptied.append(child)
            moves += try leaves(in: child)
        }
        return FolderPlan(target: folder, moves: moves, emptied: emptied)
    }

    /// Whether a folder from a plan really ended up empty, ignoring subfolders that are empty themselves.
    /// False when a person skipped a conflict, so that what stayed behind also stays out of the Trash.
    public static func isEmptied(_ folder: URL) throws -> Bool {
        for child in try children(of: folder) {
            guard try isOpenFolder(child, includingHidden: true), try isEmptied(child) else { return false }
        }
        return true
    }

    private static func requireFolder(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw BatchRenameError(.external, "\(url.lastPathComponent) is not a folder.", path: url.path)
        }
    }

    private static func children(of folder: URL) throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [])
                .filter { !ignored.contains($0.lastPathComponent) }
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        } catch {
            throw BatchRenameError(.external, "\(folder.lastPathComponent) cannot be read: \(error.localizedDescription)", path: folder.path)
        }
    }

    private static func isOpenFolder(_ url: URL, includingHidden: Bool = false) throws -> Bool {
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true, values.isPackage != true else { return false }
            return includingHidden || !url.lastPathComponent.hasPrefix(".")
        } catch {
            throw BatchRenameError(.external, "\(url.lastPathComponent) cannot be read: \(error.localizedDescription)", path: url.path)
        }
    }

    private static func leaves(in folder: URL) throws -> [URL] {
        try children(of: folder).flatMap { child in
            try isOpenFolder(child) ? try leaves(in: child) : [child]
        }
    }

    private static func isSameItem(_ a: URL, _ b: URL) -> Bool {
        var first = stat(), second = stat()
        guard lstat(a.path, &first) == 0, lstat(b.path, &second) == 0 else { return false }
        return first.st_dev == second.st_dev && first.st_ino == second.st_ino
    }

    /// `url` is `folder` or lies below it, by inode so that a link or a case variant cannot hide it
    private static func isInside(_ url: URL, folder: URL) -> Bool {
        var current = url.resolvingSymlinksInPath()
        while current.path != "/" {
            if isSameItem(current, folder) { return true }
            current.deleteLastPathComponent()
        }
        return false
    }
}
