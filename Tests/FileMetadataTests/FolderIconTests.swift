import AppKit
import FileMetadata
import HSpaceContracts
import HSpaceTestSupport
import Testing

private func hasFlag(_ url: URL) -> Bool {
    guard let info = rawAttribute("com.apple.FinderInfo", of: url), info.count == 32 else { return false }
    return info[8] & 0x04 != 0
}

private func iconFile(in url: URL) -> URL { url.appendingPathComponent("Icon\r") }

private func pixels(_ png: Data) throws -> NSBitmapImageRep {
    try #require(NSBitmapImageRep(data: png))
}

@Suite struct FolderIconRendererTests {
    @Test func picksOneEmoji() {
        #expect(FolderIconRenderer.singleEmoji(in: "🗂") == "🗂")
        #expect(FolderIconRenderer.singleEmoji(in: "x 🐢 🦊") == "🐢")
        #expect(FolderIconRenderer.singleEmoji(in: "👩‍💻") == "👩‍💻")
        #expect(FolderIconRenderer.singleEmoji(in: "plain 123") == nil)
        #expect(FolderIconRenderer.singleEmoji(in: "") == nil)
    }

    @Test func anEmojiLeavesTheCornersClear() throws {
        let image = try pixels(FolderIconRenderer.render(.emoji("🐢")))
        #expect(image.pixelsWide == 512)
        #expect(try #require(image.colorAt(x: 0, y: 0)).alphaComponent == 0)
        #expect(try #require(image.colorAt(x: 256, y: 256)).alphaComponent > 0.5)
    }

    @Test func aColourChangesTheFolder() throws {
        let plain = try pixels(FolderIconRenderer.render(.styled(color: .gray, emoji: nil)))
        let red = try pixels(FolderIconRenderer.render(.styled(color: .red, emoji: nil)))
        let a = try #require(plain.colorAt(x: 256, y: 200)?.usingColorSpace(.deviceRGB))
        let b = try #require(red.colorAt(x: 256, y: 200)?.usingColorSpace(.deviceRGB))
        #expect(b.redComponent > b.blueComponent + 0.2)
        #expect(abs(a.redComponent - b.redComponent) + abs(a.blueComponent - b.blueComponent) > 0.1)
    }

    @Test func aPictureFromAFile() throws {
        let dir = try FaultFixture.tempDir("hspace-icon")
        defer { FaultFixture.remove(dir) }
        let source = dir.appendingPathComponent("p.png")
        try FaultFixture.write(try FolderIconRenderer.render(.emoji("🐢")), to: source)
        #expect(try !FolderIconRenderer.render(.image(source)).isEmpty)
    }

    @Test func badInputIsRefused() throws {
        let dir = try FaultFixture.tempDir("hspace-icon")
        defer { FaultFixture.remove(dir) }
        let text = dir.appendingPathComponent("not-a-picture.png")
        try FaultFixture.write(to: text)
        #expect(throws: MetadataError.self) { try FolderIconRenderer.render(.image(text)) }
        #expect(throws: MetadataError.self) { try FolderIconRenderer.render(.emoji("abc")) }
        #expect(throws: MetadataError.self) { try FolderIconRenderer.render(.styled(color: nil, emoji: nil)) }
    }
}

@Suite(.serialized) struct FolderIconTests {
    let engine = FileMetadata()
    private let spec = FolderIconSpec.styled(color: .blue, emoji: "🐢")

    private func folder(in dir: URL, _ name: String = "folder") throws -> URL {
        let url = dir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func storedTheWayFinderStoresIt() async throws {
        let dir = try FaultFixture.tempDir("hspace-icon")
        defer { FaultFixture.remove(dir) }
        let target = try folder(in: dir)

        let result = try await engine.apply(.folderIcon(spec), to: [target])

        #expect(result.failures.isEmpty)
        #expect(hasFlag(target))
        #expect(FileManager.default.fileExists(atPath: iconFile(in: target).path))
        #expect(try await engine.read([target])[target]?.hasCustomIcon == true)
    }

    @Test func removingLeavesTheFolderAsItWas() async throws {
        let dir = try FaultFixture.tempDir("hspace-icon")
        defer { FaultFixture.remove(dir) }
        let target = try folder(in: dir)
        _ = try await engine.apply(.folderIcon(spec), to: [target])
        _ = try await engine.apply(.folderIcon(nil), to: [target])
        #expect(!hasFlag(target))
        #expect(!FileManager.default.fileExists(atPath: iconFile(in: target).path))
    }

    @Test func removingFromAPlainFolderChangesNothing() async throws {
        let dir = try FaultFixture.tempDir("hspace-icon")
        defer { FaultFixture.remove(dir) }
        let target = try folder(in: dir)
        let result = try await engine.apply(.folderIcon(nil), to: [target])
        #expect(result.changed.isEmpty)
        #expect(result.failures.isEmpty)
    }

    @Test func undoRestoresBothStates() async throws {
        let dir = try FaultFixture.tempDir("hspace-icon")
        defer { FaultFixture.remove(dir) }
        let plain = try folder(in: dir, "plain")
        let custom = try folder(in: dir, "custom")
        _ = try await engine.apply(.folderIcon(.emoji("🦊")), to: [custom])

        let applied = try await engine.apply(.folderIcon(spec), to: [plain, custom])
        let undone = try await engine.restore(applied.changed)
        #expect(!hasFlag(plain))
        #expect(hasFlag(custom))

        _ = try await engine.restore(undone.changed)
        #expect(hasFlag(plain))
    }

    @Test func tagsLeaveTheIconAlone() async throws {
        let dir = try FaultFixture.tempDir("hspace-icon")
        defer { FaultFixture.remove(dir) }
        let target = try folder(in: dir)
        _ = try await engine.apply(.folderIcon(spec), to: [target])
        try engine.setTags([FinderTag(name: "Red", color: .red)], on: target)
        try engine.setTags([], on: target)
        #expect(hasFlag(target))
    }

    @Test func aFileIsRefused() async throws {
        let dir = try FaultFixture.tempDir("hspace-icon")
        defer { FaultFixture.remove(dir) }
        let file = dir.appendingPathComponent("a")
        try FaultFixture.write(to: file)
        let result = try await engine.apply(.folderIcon(spec), to: [file])
        #expect(result.failures.count == 1)
        #expect(!hasFlag(file))
    }

    @Test func noPermissionFailsPerItem() async throws {
        let dir = try FaultFixture.tempDir("hspace-icon")
        defer { FaultFixture.remove(dir) }
        let target = try folder(in: dir)
        try await FaultFixture.withReadOnly(target) {
            let result = try await engine.apply(.folderIcon(spec), to: [target])
            #expect(result.failures.first?.errorClass == .external)
            #expect(result.changed.isEmpty)
        }
        #expect(!hasFlag(target))
    }

    @Test func aMissingFolderFailsPerItem() async throws {
        let dir = try FaultFixture.tempDir("hspace-icon")
        defer { FaultFixture.remove(dir) }
        let result = try await engine.apply(.folderIcon(spec), to: [dir.appendingPathComponent("gone")])
        #expect(result.failures.count == 1)
    }

    @Test func anEjectedVolumeFailsPerItem() async throws {
        let volume = try ScratchVolume()
        let target = try folder(in: volume.url)
        try volume.eject()
        let result = try await engine.apply(.folderIcon(spec), to: [target])
        #expect(result.failures.first?.errorClass == .external)
    }

    @Test func aFullDiskFails() async throws {
        let volume = try ScratchVolume()
        let target = try folder(in: volume.url)
        try volume.fill(leaving: 0)
        let result = try await engine.apply(.folderIcon(spec), to: [target])
        #expect(result.failures.count == 1)
        #expect(!hasFlag(target))
    }

    @Test func aBadSpecStopsBeforeAnyWrite() async throws {
        let dir = try FaultFixture.tempDir("hspace-icon")
        defer { FaultFixture.remove(dir) }
        let target = try folder(in: dir)
        await #expect(throws: MetadataError.self) {
            try await engine.apply(.folderIcon(.emoji("abc")), to: [target])
        }
        #expect(!hasFlag(target))
    }

    @Test func cancellingPutsIconsBack() async throws {
        let dir = try FaultFixture.tempDir("hspace-icon")
        defer { FaultFixture.remove(dir) }
        let urls = try (0..<6).map { try folder(in: dir, "f\($0)") }
        let engine = engine
        let spec = spec
        let task = Task {
            try await engine.apply(.folderIcon(spec), to: urls) { done, _ in
                if done == 2 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(urls.allSatisfy { !hasFlag($0) })
    }
}
