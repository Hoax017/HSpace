import Testing
import Foundation
import HSpaceTestSupport

/// The fixtures must produce real OS failures, otherwise every test built on them proves nothing.
@Suite struct HSpaceTestSupportTests {
    @Test func unreadableDirectoryCannotBeListed() async throws {
        let dir = try FaultFixture.tempDir()
        defer { FaultFixture.remove(dir) }
        try await FaultFixture.withUnreadable(dir) {
            #expect(throws: (any Error).self) {
                try FileManager.default.contentsOfDirectory(atPath: dir.path)
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func readOnlyDirectoryRejectsWrites() async throws {
        let dir = try FaultFixture.tempDir()
        defer { FaultFixture.remove(dir) }
        try await FaultFixture.withReadOnly(dir) {
            #expect(throws: (any Error).self) {
                try Data("x".utf8).write(to: dir.appendingPathComponent("new"))
            }
        }
    }

    @Test func linksAreRealLinks() throws {
        let dir = try FaultFixture.tempDir()
        defer { FaultFixture.remove(dir) }
        let dangling = try FaultFixture.danglingLink(at: dir.appendingPathComponent("broken"))
        let loop = try FaultFixture.cyclicLink(in: dir)
        #expect(!FileManager.default.fileExists(atPath: dangling.path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: loop.path) == dir.path)
    }

    @Test func volumeIsSeparateFromTheTemporaryDirectory() throws {
        let volume = try ScratchVolume()
        let dir = try FaultFixture.tempDir()
        defer { FaultFixture.remove(dir) }
        let key: Set<URLResourceKey> = [.volumeIdentifierKey]
        let a = try volume.url.resourceValues(forKeys: key).volumeIdentifier as? NSObject
        let b = try dir.resourceValues(forKeys: key).volumeIdentifier as? NSObject
        #expect(a != nil && a != b)
    }

    @Test func fullVolumeRejectsLargeWrites() throws {
        let volume = try ScratchVolume()
        try volume.fill()
        #expect(throws: (any Error).self) {
            try Data(count: 2 * 1024 * 1024).write(to: volume.url.appendingPathComponent("big"),
                                                   options: .atomic)
        }
    }

    @Test func ejectUnmountsTheVolume() throws {
        let volume = try ScratchVolume()
        let file = volume.url.appendingPathComponent("file")
        try FaultFixture.write(to: file)
        try volume.eject()
        #expect(!volume.isMounted)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
