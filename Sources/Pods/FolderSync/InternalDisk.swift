import CryptoKit
import Darwin
import Foundation

enum ItemType: Sendable, Hashable { case file, folder, link }

/// One directory entry as lstat sees it: links are items, never followed.
struct DiskItem: Sendable {
    let name: String
    let url: URL
    let type: ItemType
    let size: Int64
    let modified: Double
}

/// What an item looked like at plan time. For a folder it sums the whole tree, so that a file
/// added inside a folder planned for deletion counts as a change.
struct DiskMark: Sendable, Hashable {
    let type: ItemType
    let size: Int64
    let modified: Double
    let count: Int
}

enum Disk {
    static func item(at url: URL) -> DiskItem? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        let type: ItemType = switch info.st_mode & S_IFMT {
        case S_IFDIR: .folder
        case S_IFLNK: .link
        default: .file
        }
        let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        return DiskItem(name: url.lastPathComponent, url: url, type: type, size: Int64(info.st_size), modified: modified)
    }

    /// Children of a folder. Throws when it cannot be read: an empty answer here would mean "nothing there".
    static func list(_ folder: URL) throws -> [DiskItem] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).compactMap {
            item(at: folder.appendingPathComponent($0))
        }
    }

    static func exists(_ url: URL) -> Bool { item(at: url) != nil }

    /// nil when the item is gone or a folder inside cannot be read
    static func mark(of url: URL) -> DiskMark? {
        guard let item = item(at: url) else { return nil }
        guard item.type == .folder else {
            return DiskMark(type: item.type, size: item.size, modified: item.modified, count: 1)
        }
        guard let children = try? list(url) else { return nil }
        var size: Int64 = 0, count = 0
        var modified = item.modified
        for child in children {
            guard let mark = mark(of: child.url) else { return nil }
            size += mark.size
            count += mark.count
            modified = max(modified, mark.modified)
        }
        return DiskMark(type: .folder, size: size, modified: modified, count: count)
    }

    static func linkTarget(_ url: URL) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }

    static func sameContents(_ a: URL, _ b: URL) throws -> Bool {
        try digest(a) == digest(b)
    }

    private static func digest(_ url: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk = try autoreleasepool { try handle.read(upToCount: 1 << 20) }
            guard let chunk, !chunk.isEmpty else { return hasher.finalize() }
            hasher.update(data: chunk)
        }
    }
}

/// Filter decisions, on paths relative to the compared folder.
struct FilterRules {
    let filter: SyncFilter

    /// Whether a folder is entered at all
    func allowsFolder(_ relativePath: String, name: String) -> Bool {
        !hidden(name) && !matches(filter.exclude, relativePath, name)
    }

    func allowsFile(_ relativePath: String, name: String) -> Bool {
        guard allowsFolder(relativePath, name: name) else { return false }
        return filter.include.isEmpty || matches(filter.include, relativePath, name)
    }

    private func hidden(_ name: String) -> Bool { filter.skipHidden && name.hasPrefix(".") }

    private func matches(_ patterns: [String], _ relativePath: String, _ name: String) -> Bool {
        patterns.contains { pattern in
            fnmatch(pattern, pattern.contains("/") ? relativePath : name, FNM_CASEFOLD) == 0
        }
    }
}
