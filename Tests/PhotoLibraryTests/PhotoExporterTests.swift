import CoreGraphics
import Foundation
import HSpaceContracts
import HSpaceTestSupport
import PhotoLibrary
import Testing

/// Stand-in for the library. Files are real, so the exporter meets real disks.
private struct FakeLibrary: PhotoLibraryProviding {
    var names: [String: String] = [:]
    var failing: Set<String> = []
    /// Writes half a file, then throws
    var dyingMidWrite: Set<String> = []
    var payload = Data("original".utf8)
    /// Cancels this task right after writing
    var onWrite: (@Sendable () -> Void)?

    func access() -> PhotoAccess { .granted }
    func requestAccess() async -> PhotoAccess { .granted }
    func collections() async throws -> [PhotoCollection] { [] }
    func assets(in collection: PhotoCollection) async throws -> [PhotoAsset] { [] }
    func thumbnail(of asset: PhotoAsset, side: CGFloat) async -> CGImage? { nil }

    func originalFilename(of asset: PhotoAsset) async throws -> String {
        if failing.contains(asset.id) { throw PhotoLibraryError(.external, "gone \(asset.id)") }
        return names[asset.id] ?? "\(asset.id).jpg"
    }

    func writeOriginal(of asset: PhotoAsset, to url: URL) async throws {
        if dyingMidWrite.contains(asset.id) {
            try payload.prefix(2).write(to: url)
            throw PhotoLibraryError(.transient, "the connection dropped")
        }
        try payload.write(to: url)
        onWrite?()
    }
}

@Suite struct PhotoExporterTests {
    private func asset(_ id: String) -> PhotoAsset {
        PhotoAsset(id: id, isVideo: false, created: nil, pixelWidth: 1, pixelHeight: 1)
    }

    private func names(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    @Test func originalsArriveUnderTheirOwnNames() async throws {
        let dir = try FaultFixture.tempDir("hspace-photos")
        defer { FaultFixture.remove(dir) }
        let report = await PhotoExporter(library: FakeLibrary(names: ["a": "IMG_1.HEIC"])).export([asset("a")], to: dir)
        #expect(report.exported == [dir.appendingPathComponent("IMG_1.HEIC")])
        #expect(report.failures.isEmpty)
        #expect(try Data(contentsOf: dir.appendingPathComponent("IMG_1.HEIC")) == Data("original".utf8))
        #expect(try names(in: dir) == ["IMG_1.HEIC"])
    }

    @Test func aTakenNameGetsANumberAndTheOldFileStays() async throws {
        let dir = try FaultFixture.tempDir("hspace-photos")
        defer { FaultFixture.remove(dir) }
        try FaultFixture.write(Data("mine".utf8), to: dir.appendingPathComponent("IMG.jpg"))
        let library = FakeLibrary(names: ["a": "IMG.jpg", "b": "IMG.jpg"])
        let report = await PhotoExporter(library: library).export([asset("a"), asset("b")], to: dir)
        #expect(report.exported.map(\.lastPathComponent) == ["IMG 2.jpg", "IMG 3.jpg"])
        #expect(try Data(contentsOf: dir.appendingPathComponent("IMG.jpg")) == Data("mine".utf8))
    }

    @Test func aNameCannotLeaveTheFolder() async throws {
        let dir = try FaultFixture.tempDir("hspace-photos")
        defer { FaultFixture.remove(dir) }
        let library = FakeLibrary(names: ["a": "../../evil.jpg", "b": ".."])
        let report = await PhotoExporter(library: library).export([asset("a"), asset("b")], to: dir)
        #expect(report.exported.allSatisfy { $0.deletingLastPathComponent().path == dir.path })
        #expect(report.exported.count == 2)
    }

    @Test func oneFailureDoesNotStopTheRest() async throws {
        let dir = try FaultFixture.tempDir("hspace-photos")
        defer { FaultFixture.remove(dir) }
        let report = await PhotoExporter(library: FakeLibrary(failing: ["b"])).export([asset("a"), asset("b"), asset("c")], to: dir)
        #expect(report.exported.map(\.lastPathComponent) == ["a.jpg", "c.jpg"])
        #expect(report.failures == [PhotoExportFailure(assetID: "b", message: "gone b")])
    }

    @Test func aDownloadThatDiesLeavesNoPartialFile() async throws {
        let dir = try FaultFixture.tempDir("hspace-photos")
        defer { FaultFixture.remove(dir) }
        let report = await PhotoExporter(library: FakeLibrary(dyingMidWrite: ["a"])).export([asset("a")], to: dir)
        #expect(report.failures.count == 1)
        #expect(try names(in: dir).isEmpty)
    }

    @Test func cancellingLeavesWhatFinishedAndNothingElse() async throws {
        let dir = try FaultFixture.tempDir("hspace-photos")
        defer { FaultFixture.remove(dir) }
        let box = TaskBox()
        let library = FakeLibrary(onWrite: { box.cancelAfterFirstWrite() })
        let task = Task { await PhotoExporter(library: library).export([asset("a"), asset("b")], to: dir) }
        box.task = task
        let report = await task.value
        #expect(report.cancelled)
        #expect(try names(in: dir).allSatisfy { !$0.hasPrefix(".hspace-partial") })
        #expect(report.exported.count <= 1)
    }

    @Test func alreadyCancelledDoesNothing() async throws {
        let dir = try FaultFixture.tempDir("hspace-photos")
        defer { FaultFixture.remove(dir) }
        let exporting = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await PhotoExporter(library: FakeLibrary()).export([asset("a")], to: dir)
        }
        let report = await exporting.value
        #expect(report.cancelled)
        #expect(try names(in: dir).isEmpty)
    }

    @Test func aFolderThatCannotBeWrittenFailsEachItemClearly() async throws {
        let dir = try FaultFixture.tempDir("hspace-photos")
        defer { FaultFixture.remove(dir) }
        let report = try await FaultFixture.withReadOnly(dir) {
            await PhotoExporter(library: FakeLibrary()).export([asset("a")], to: dir)
        }
        #expect(report.exported.isEmpty)
        #expect(report.failures.count == 1)
    }

    @Test func aFullDiskLeavesNoPartialFile() async throws {
        let volume = try ScratchVolume(sizeMB: 2)
        defer { try? volume.eject() }
        let report = await PhotoExporter(library: FakeLibrary(payload: Data(repeating: 1, count: 8_000_000)))
            .export([asset("a")], to: volume.url)
        #expect(report.exported.isEmpty)
        #expect(report.failures.count == 1)
        let left = try FileManager.default.contentsOfDirectory(atPath: volume.url.path)
        #expect(!left.contains { $0.hasPrefix(".hspace-partial") })
    }

    @Test func progressCountsEveryItem() async throws {
        let dir = try FaultFixture.tempDir("hspace-photos")
        defer { FaultFixture.remove(dir) }
        let seen = Progress()
        _ = await PhotoExporter(library: FakeLibrary(failing: ["b"])).export([asset("a"), asset("b")], to: dir) { done, total in
            seen.record(done, total)
        }
        #expect(seen.values == [[1, 2], [2, 2]])
    }
}

private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Task<PhotoExportReport, Never>?
    private var writes = 0

    var task: Task<PhotoExportReport, Never>? {
        get { lock.withLock { stored } }
        set {
            lock.withLock {
                stored = newValue
                if writes > 0 { newValue?.cancel() }
            }
        }
    }

    func cancelAfterFirstWrite() {
        lock.withLock {
            writes += 1
            stored?.cancel()
        }
    }
}

private final class Progress: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[Int]] = []
    var values: [[Int]] { lock.withLock { stored } }
    func record(_ done: Int, _ total: Int) { lock.withLock { stored.append([done, total]) } }
}
