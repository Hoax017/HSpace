import Foundation

public enum ScratchVolumeError: Error {
    case tool(String)
}

/// A real, small mounted volume. Use it for cross-volume transfers, disk-full and ejected-volume tests.
public final class ScratchVolume: @unchecked Sendable {
    public let url: URL
    private let imageDir: URL
    private let lock = NSLock()
    private var mounted = true

    public init(sizeMB: Int = 8) throws {
        imageDir = try FaultFixture.tempDir("hspace-volume")
        url = imageDir.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let image = imageDir.appendingPathComponent("volume.dmg").path
        try Self.hdiutil(["create", "-quiet", "-size", "\(sizeMB)m", "-fs", "APFS",
                          "-volname", "HSpaceTest", image])
        try Self.hdiutil(["attach", "-quiet", "-nobrowse", "-noverify", "-noautoopen",
                          "-mountpoint", url.path, image])
    }

    deinit {
        if isMounted { try? eject() }
        FaultFixture.remove(imageDir)
    }

    public var isMounted: Bool {
        lock.lock(); defer { lock.unlock() }
        return mounted
    }

    /// Forcibly unmounts, as when a drive is unplugged. Open files start failing.
    public func eject() throws {
        lock.lock(); defer { lock.unlock() }
        guard mounted else { return }
        try Self.hdiutil(["detach", "-quiet", "-force", url.path])
        mounted = false
    }

    public var availableBytes: Int64 {
        get throws {
            let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            return Int64(values.volumeAvailableCapacity ?? 0)
        }
    }

    /// Fills the volume until at most `leaving` bytes remain, so the next large write gets ENOSPC.
    public func fill(leaving: Int64 = 64 * 1024) throws {
        let filler = url.appendingPathComponent(".filler-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: filler.path, contents: nil) else {
            throw ScratchVolumeError.tool("cannot create filler")
        }
        let handle = try FileHandle(forWritingTo: filler)
        defer { try? handle.close() }
        let chunk = Data(repeating: 0xA5, count: 64 * 1024)
        while try availableBytes > leaving + Int64(chunk.count) {
            do { try handle.write(contentsOf: chunk) } catch { break }
        }
        try? handle.synchronize()
    }

    private static func hdiutil(_ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = args
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ScratchVolumeError.tool(String(decoding: message, as: UTF8.self))
        }
    }
}
