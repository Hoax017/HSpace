import AppKit
import CoreGraphics
import HSpaceContracts
import PhotoLibrary
import Testing
@testable import HSpaceApp

private final class Stub: PhotoLibraryProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var currentAccess: PhotoAccess
    private var answer: PhotoAccess
    private var touched = false
    var collectionsError: PhotoLibraryError?
    var albumError: PhotoLibraryError?
    /// Assets of an album, slower for "slow"
    var delays: [String: Duration] = [:]

    init(access: PhotoAccess, answer: PhotoAccess = .granted) {
        currentAccess = access
        self.answer = answer
    }

    var libraryWasTouched: Bool { lock.withLock { touched } }

    func access() -> PhotoAccess { lock.withLock { currentAccess } }
    func requestAccess() async -> PhotoAccess {
        lock.withLock {
            currentAccess = answer
            return answer
        }
    }
    func collections() async throws -> [PhotoCollection] {
        lock.withLock { touched = true }
        if let collectionsError { throw collectionsError }
        return [PhotoCollection(id: "all", title: "All", kind: .allPhotos), PhotoCollection(id: "slow", title: "Slow", kind: .album)]
    }
    func assets(in collection: PhotoCollection) async throws -> [PhotoAsset] {
        lock.withLock { touched = true }
        if let delay = delays[collection.id] { try await Task.sleep(for: delay) }
        if let albumError, collection.id == "slow" { throw albumError }
        return [PhotoAsset(id: collection.id, isVideo: false, created: nil, pixelWidth: 1, pixelHeight: 1)]
    }
    func thumbnail(of asset: PhotoAsset, side: CGFloat) async -> CGImage? { nil }
    func originalFilename(of asset: PhotoAsset) async throws -> String { "x" }
    func writeOriginal(of asset: PhotoAsset, to url: URL) async throws {}
}

@MainActor @Suite struct PhotosBrowserTests {
    @Test func grantedAccessShowsTheFirstAlbum() async {
        let model = PhotosBrowserModel(library: Stub(access: .granted))
        await model.start()
        #expect(model.state == .ready)
        #expect(model.collections.count == 2)
        #expect(model.assets.map(\.id) == ["all"])
        #expect(model.message == nil)
    }

    @Test func limitedAccessWorksToo() async {
        let model = PhotosBrowserModel(library: Stub(access: .limited))
        await model.start()
        #expect(model.state == .ready)
    }

    @Test func nothingIsAskedOrReadBeforeTheOwnerPressesAllow() async {
        let stub = Stub(access: .notDetermined)
        let model = PhotosBrowserModel(library: stub)
        await model.start()
        #expect(model.state == .needsPermission)
        #expect(!stub.libraryWasTouched)
    }

    @Test func allowingLoadsTheLibrary() async {
        let model = PhotosBrowserModel(library: Stub(access: .notDetermined))
        await model.start()
        await model.requestAccess()
        #expect(model.state == .ready)
        #expect(!model.assets.isEmpty)
    }

    @Test func refusingAtThePromptEndsDeniedAndReadsNothing() async {
        let stub = Stub(access: .notDetermined, answer: .denied)
        let model = PhotosBrowserModel(library: stub)
        await model.start()
        await model.requestAccess()
        #expect(model.state == .denied)
        #expect(model.message != nil)
        #expect(!stub.libraryWasTouched)
    }

    @Test func anEarlierDenialReadsNothing() async {
        let stub = Stub(access: .denied)
        let model = PhotosBrowserModel(library: stub)
        await model.start()
        #expect(model.state == .denied)
        #expect(!stub.libraryWasTouched)
    }

    @Test func aDevicePolicySaysSo() async {
        let model = PhotosBrowserModel(library: Stub(access: .restricted))
        await model.start()
        #expect(model.state == .restricted)
    }

    @Test func aLibraryThatFailsSaysWhy() async {
        let stub = Stub(access: .granted)
        stub.collectionsError = PhotoLibraryError(.external, "no library")
        let model = PhotosBrowserModel(library: stub)
        await model.start()
        #expect(model.state == .failed("no library"))
    }

    @Test func anAlbumThatFailsSaysWhy() async {
        let stub = Stub(access: .granted)
        stub.albumError = PhotoLibraryError(.external, "album gone")
        let model = PhotosBrowserModel(library: stub)
        await model.start()
        await model.show(model.collections[1])
        #expect(model.state == .failed("album gone"))
    }

    @Test func aSlowAlbumCannotReplaceANewerChoice() async throws {
        let stub = Stub(access: .granted)
        stub.delays["slow"] = .milliseconds(300)
        let model = PhotosBrowserModel(library: stub)
        await model.start()
        let slow = model.collections[1]
        let all = model.collections[0]
        let waiting = Task { await model.show(slow) }
        try await Task.sleep(for: .milliseconds(20))
        await model.show(all)
        await waiting.value
        #expect(model.current == all)
        #expect(model.assets.map(\.id) == ["all"])
    }

    @Test func thePlistSaysWhyPhotosAreNeeded() throws {
        // Without this key, asking macOS for access ends the process instead of showing the prompt
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Support/Info.plist")
        let values = try #require(NSDictionary(contentsOf: plist))
        let text = try #require(values["NSPhotoLibraryUsageDescription"] as? String)
        #expect(!text.isEmpty)
    }
}
