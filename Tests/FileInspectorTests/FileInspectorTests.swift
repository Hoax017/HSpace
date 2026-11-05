import CoreGraphics
import FileInspector
import Foundation
import HSpaceContracts
import HSpaceTestSupport
import ImageIO
import Testing
import UniformTypeIdentifiers

@Suite struct FileInspectorTests {
    private let inspector: any FileInspecting = FileInspector()

    private func writePNG(to url: URL, width: Int, height: Int) throws {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func aFileGivesItsBasics() async throws {
        let dir = try FaultFixture.tempDir("hspace-inspector")
        defer { FaultFixture.remove(dir) }
        let file = dir.appendingPathComponent("note.txt")
        try FaultFixture.write(Data("hello".utf8), to: file)
        chmod(file.path, 0o640)

        let facts = try await inspector.inspect(file)
        #expect(facts.name == "note.txt")
        #expect(facts.typeID == UTType.plainText.identifier)
        #expect(facts.logicalSize == 5)
        #expect(facts.isDirectory == false)
        #expect(facts.permissions == 0o640)
        #expect(facts.owner == NSUserName())
        #expect(facts.modified != nil)
        #expect(facts.childCount == nil)
    }

    @Test func aFolderCountsItsDirectChildrenAndHasNoSize() async throws {
        let dir = try FaultFixture.tempDir("hspace-inspector")
        defer { FaultFixture.remove(dir) }
        try FaultFixture.write(to: dir.appendingPathComponent("a"))
        try FaultFixture.write(to: dir.appendingPathComponent("sub/b"))

        let facts = try await inspector.inspect(dir)
        #expect(facts.isDirectory)
        #expect(facts.childCount == 2)
        #expect(facts.logicalSize == nil)
    }

    @Test func anImageGivesItsPixels() async throws {
        let dir = try FaultFixture.tempDir("hspace-inspector")
        defer { FaultFixture.remove(dir) }
        let file = dir.appendingPathComponent("p.png")
        try writePNG(to: file, width: 12, height: 8)

        let image = try #require(try await inspector.inspect(file).image)
        #expect(image.pixelWidth == 12)
        #expect(image.pixelHeight == 8)
    }

    @Test func aDamagedImageStillGivesItsOtherFacts() async throws {
        let dir = try FaultFixture.tempDir("hspace-inspector")
        defer { FaultFixture.remove(dir) }
        let file = dir.appendingPathComponent("bad.png")
        try FaultFixture.write(Data("not a png".utf8), to: file)

        let facts = try await inspector.inspect(file)
        #expect(facts.image == nil)
        #expect(facts.logicalSize == 9)
    }

    @Test func aPDFGivesItsPages() async throws {
        let dir = try FaultFixture.tempDir("hspace-inspector")
        defer { FaultFixture.remove(dir) }
        let file = dir.appendingPathComponent("doc.pdf")
        let context = try #require(CGContext(file as CFURL, mediaBox: nil, nil))
        for _ in 0..<3 { context.beginPDFPage(nil); context.endPDFPage() }
        context.closePDF()

        #expect(try await inspector.inspect(file).pageCount == 3)
    }

    @Test func aDamagedMediaFileStillGivesItsOtherFacts() async throws {
        let dir = try FaultFixture.tempDir("hspace-inspector")
        defer { FaultFixture.remove(dir) }
        let file = dir.appendingPathComponent("clip.mov")
        try FaultFixture.write(Data(repeating: 7, count: 64), to: file)

        let facts = try await inspector.inspect(file)
        #expect(facts.logicalSize == 64)
        #expect(facts.media == nil || facts.media?.videoWidth == nil)
    }

    @Test func aLinkIsDescribedItself() async throws {
        let dir = try FaultFixture.tempDir("hspace-inspector")
        defer { FaultFixture.remove(dir) }
        let target = dir.appendingPathComponent("target.png")
        try writePNG(to: target, width: 4, height: 4)
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "target.png")

        let facts = try await inspector.inspect(link)
        #expect(facts.isSymlink)
        #expect(facts.linkTarget == "target.png")
        #expect(facts.linkIsBroken == false)
        #expect(facts.image == nil)
    }

    @Test func aBrokenLinkSaysSo() async throws {
        let dir = try FaultFixture.tempDir("hspace-inspector")
        defer { FaultFixture.remove(dir) }
        let link = try FaultFixture.danglingLink(at: dir.appendingPathComponent("dead"))

        let facts = try await inspector.inspect(link)
        #expect(facts.isSymlink)
        #expect(facts.linkIsBroken)
    }

    @Test func aMissingItemFailsWithItsName() async throws {
        let dir = try FaultFixture.tempDir("hspace-inspector")
        defer { FaultFixture.remove(dir) }
        await #expect {
            try await inspector.inspect(dir.appendingPathComponent("gone.txt"))
        } throws: { error in
            let failure = error as? InspectorError
            return failure?.errorClass == .external && failure?.localizedDescription.contains("gone.txt") == true
        }
    }

    @Test func aFolderItCannotListStillGivesItsAttributes() async throws {
        let dir = try FaultFixture.tempDir("hspace-inspector")
        defer { FaultFixture.remove(dir) }
        let locked = dir.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let facts = try await FaultFixture.withUnreadable(locked) { try await inspector.inspect(locked) }
        #expect(facts.isDirectory)
        #expect(facts.childCount == nil)
        #expect(facts.permissions == 0)
    }

    @Test func anItemInsideAnUnreadableFolderFailsClearly() async throws {
        let dir = try FaultFixture.tempDir("hspace-inspector")
        defer { FaultFixture.remove(dir) }
        let locked = dir.appendingPathComponent("locked")
        let inside = locked.appendingPathComponent("a")
        try FaultFixture.write(to: inside)
        try await FaultFixture.withMode(0o000, on: locked) {
            await #expect(throws: InspectorError.self) { try await inspector.inspect(inside) }
        }
    }

    @Test func cancellingStopsTheRead() async throws {
        let dir = try FaultFixture.tempDir("hspace-inspector")
        defer { FaultFixture.remove(dir) }
        let task = Task {
            try await Task.sleep(for: .seconds(30))
            return try await inspector.inspect(dir)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

@Suite struct PermissionsTests {
    @Test func plainModes() {
        #expect(Permissions.symbolic(0o755) == "rwxr-xr-x")
        #expect(Permissions.symbolic(0o640) == "rw-r-----")
        #expect(Permissions.symbolic(0) == "---------")
        #expect(Permissions.octal(0o755) == "755")
    }

    @Test func specialBits() {
        #expect(Permissions.symbolic(0o4755) == "rwsr-xr-x")
        #expect(Permissions.symbolic(0o2644) == "rw-r-Sr--")
        #expect(Permissions.symbolic(0o1777) == "rwxrwxrwt")
        #expect(Permissions.octal(0o1777) == "1777")
    }
}

@Suite struct SelectionTallyTests {
    private func item(_ name: String, folder: Bool = false, size: Int64? = nil, type: String? = "public.data") -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/x/\(name)"), name: name, isDirectory: folder, isPackage: false,
                 isSymlink: false, isHidden: false, size: size, modified: nil, created: nil, contentTypeID: type)
    }

    @Test func filesAloneAreComplete() {
        let tally = SelectionTally([item("a", size: 2), item("b", size: 3)])
        #expect(tally.count == 2)
        #expect(tally.bytes == 5)
        #expect(tally.isPartial == false)
        #expect(tally.sharedTypeID == "public.data")
    }

    @Test func aFolderLeavesItPartialUntilItsSizeArrives() {
        let tally = SelectionTally([item("a", size: 2), item("d", folder: true, type: "public.folder")])
        #expect(tally.isPartial)
        #expect(tally.folders == 1)
        #expect(tally.sharedTypeID == nil)
        let done = tally.adding(folderBytes: 10, complete: true)
        #expect(done.bytes == 12)
        #expect(done.isPartial == false)
        #expect(tally.adding(folderBytes: 10, complete: false).isPartial)
    }
}
