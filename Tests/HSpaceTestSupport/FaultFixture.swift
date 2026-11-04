import Foundation

/// Real failure conditions for tests: no mocks, every helper produces the actual OS error.
public enum FaultFixture {
    public static func tempDir(_ prefix: String = "hspace-fault") throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .resolvingSymlinksInPath()
        let url = base.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Removes a fixture even when a test left restrictive permissions inside it.
    public static func remove(_ url: URL) {
        if let walker = FileManager.default.enumerator(atPath: url.path) {
            chmod(url.path, 0o755)
            while let child = walker.nextObject() as? String {
                chmod(url.appendingPathComponent(child).path, 0o755)
            }
        }
        try? FileManager.default.removeItem(at: url)
    }

    /// Runs `body` with `url` set to `mode`, then restores the original mode.
    public static func withMode<T>(_ mode: mode_t, on url: URL,
                                   _ body: () async throws -> T) async throws -> T {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(.ENOENT) }
        guard chmod(url.path, mode) == 0 else { throw POSIXError(.EPERM) }
        defer { chmod(url.path, info.st_mode & 0o7777) }
        return try await body()
    }

    /// Directory that exists but cannot be listed.
    public static func withUnreadable<T>(_ url: URL, _ body: () async throws -> T) async throws -> T {
        try await withMode(0o000, on: url, body)
    }

    /// Directory that can be listed but where nothing can be created or removed.
    public static func withReadOnly<T>(_ url: URL, _ body: () async throws -> T) async throws -> T {
        try await withMode(0o555, on: url, body)
    }

    public static func write(_ data: Data = Data("payload".utf8), to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// Symlink whose target does not exist.
    @discardableResult
    public static func danglingLink(at url: URL) throws -> URL {
        try FileManager.default.createSymbolicLink(atPath: url.path,
                                                   withDestinationPath: "missing-\(UUID().uuidString)")
        return url
    }

    /// `dir/loop` points back to `dir`.
    @discardableResult
    public static func cyclicLink(in dir: URL, named name: String = "loop") throws -> URL {
        let link = dir.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
        return link
    }
}
