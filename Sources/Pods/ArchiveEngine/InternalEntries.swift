import Foundation
import HSpaceContracts

// Private concern: taking chosen entries out of an archive, without extracting the rest.
// tar reads the names as patterns, from a file so that no name can pass for an option. Each one is escaped
// and anchored: "a.txt" alone would also match "sub/a.txt", and "*" would match everything.
// tar runs without -P: it refuses paths with ".." and writes nothing through a symlink, and `landed` checks that afterwards.

extension ArchiveEngineNode {
    func extractEntries(_ entries: [ArchiveEntry], from archive: URL, into directory: URL,
                        password: String? = nil) async throws -> [URL] {
        guard let format = ArchiveFormat.detect(archive) else {
            throw ArchiveError(.logic, "Unrecognized archive format:\(archive.lastPathComponent)", path: archive.path)
        }
        if let unsafe = entries.first(where: { !$0.isSafe }) {
            throw ArchiveError(.logic, "Unsafe path in the archive: \(unsafe.path)", path: archive.path)
        }
        guard !entries.isEmpty else { return [] }
        switch format {
        case .gzip, .bzip2, .xz:
            try await extractSingleStream(archive, format: format, into: directory)
        default:
            try await extractWithTar(entries, from: archive, into: directory, password: password)
        }
        return try entries.map { try Self.landed($0, in: directory) }
    }

    func extractPreview(_ entries: [ArchiveEntry], from archive: URL, into directory: URL, password: String?,
                        byteLimit: Int64) async throws -> [(entry: ArchiveEntry, url: URL)] {
        let files = entries.filter { $0.kind == .file && $0.isSafe }
        let total = files.reduce(Int64(0)) { $0.addingReportingOverflow($1.size ?? 0).partialValue }
        guard total >= 0, total <= byteLimit else {
            throw ArchiveError(.logic, "Too large to preview. Extract it instead.", path: archive.path)
        }
        let landed = try await extractEntries(files, from: archive, into: directory, password: password)
        return zip(files, landed).filter { Self.isRegularFile($0.1) }.map { (entry: $0.0, url: $0.1) }
    }

    /// True only for a real file: a symlink is not one, whatever it points at
    private static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    private func extractWithTar(_ entries: [ArchiveEntry], from archive: URL, into directory: URL,
                                password: String?) async throws {
        let list = FileManager.default.temporaryDirectory.appendingPathComponent("hspace-entries-\(UUID().uuidString)")
        do {
            try Data(entries.flatMap { Self.pattern(for: $0.rawPath) + [0] }).write(to: list)
        } catch {
            throw ArchiveError(.external, "Could not prepare extraction: \(error.localizedDescription)", path: list.path)
        }
        defer { try? FileManager.default.removeItem(at: list) }     // Names only, in the temporary directory
        let arguments = ["-xf", archive.path, "-C", directory.path, "--null", "-T", list.path]
        if let password, !password.isEmpty {
            try await runWithPassword(Tools.tar, arguments, password: password, archive: archive)
        } else {
            try await runArchiveTool(Tools.tar, arguments, utf8Locale: true)
        }
    }

    /// An anchored tar pattern that matches this path and, for a folder, what is under it
    static func pattern(for rawPath: [UInt8]) -> [UInt8] {
        var path = rawPath
        while path.count > 1, path.last == UInt8(ascii: "/") { path.removeLast() }
        var pattern = [UInt8(ascii: "^")]
        let special = Array("\\*?[]^$".utf8)
        for byte in path {
            if special.contains(byte) { pattern.append(UInt8(ascii: "\\")) }
            pattern.append(byte)
        }
        return pattern
    }

    /// Where an entry landed. Every folder on the way must be a real folder inside `directory`.
    private static func landed(_ entry: ArchiveEntry, in directory: URL) throws -> URL {
        var bytes = Array(directory.path.utf8)
        let components = ArchiveEntry.components(of: entry.rawPath)
        for (depth, component) in components.enumerated() {
            bytes += [UInt8(ascii: "/")] + component
            var info = stat()
            guard bytes.withCString({ lstat($0, &info) }) == 0 else {
                throw ArchiveError(.external, "\(entry.path) did not come out of the archive", path: directory.path)
            }
            if depth < components.count - 1, (info.st_mode & S_IFMT) != S_IFDIR {
                throw ArchiveError(.external, "\(entry.path) leads out of the extraction folder", path: directory.path)
            }
        }
        return bytes.withCString { URL(fileURLWithFileSystemRepresentation: $0, isDirectory: false, relativeTo: nil) }
    }

    static func createScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hspace-archive-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw ArchiveError(.external, "Could not create a temporary folder: \(error.localizedDescription)", path: url.path)
        }
        return url
    }

    /// Archives can create folders without write permission, and nothing in those can be removed until that changes.
    static func removeScratchDirectory(_ url: URL) throws {
        let fm = FileManager.default
        guard itemExists(url) else { return }
        if let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]) {
            for case let item as URL in walker {
                // Each folder opens up before the walk goes into it. A symlink is never followed or changed.
                let values = try? item.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                if values?.isDirectory == true, values?.isSymbolicLink != true { chmod(item.path, 0o700) }
            }
        }
        do {
            try fm.removeItem(at: url)
        } catch {
            throw ArchiveError(.external, "Could not remove a temporary folder: \(error.localizedDescription)", path: url.path)
        }
    }
}

extension Array where Element == UInt8 {
    /// The bytes as a C string
    func withCString<T>(_ body: (UnsafePointer<CChar>) -> T) -> T {
        let terminated = map { CChar(bitPattern: $0) } + [0]
        return terminated.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}
