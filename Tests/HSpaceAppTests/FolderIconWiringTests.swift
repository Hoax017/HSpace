import AppKit
import FileMetadata
import HSpaceContracts
import HSpaceTestSupport
import Testing
@testable import HSpaceApp

@Suite struct FolderIconChoiceTests {
    @Test func nothingChosenGivesNothing() {
        #expect(FolderIconChoice().spec == nil)
        #expect(FolderIconChoice(emojiText: "plain").spec == nil)
    }

    @Test func colourAndEmojiMakeAStyle() {
        #expect(FolderIconChoice(color: .red).spec == .styled(color: .red, emoji: nil))
        #expect(FolderIconChoice(color: .red, emojiText: "🐢").spec == .styled(color: .red, emoji: "🐢"))
    }

    @Test func emojiCanStandAlone() {
        #expect(FolderIconChoice(emojiText: "🐢", emojiAlone: true).spec == .emoji("🐢"))
        #expect(FolderIconChoice(color: .red, emojiAlone: true).spec == .styled(color: .red, emoji: nil))
    }

    @Test func aPictureWins() {
        let url = URL(fileURLWithPath: "/x.png")
        #expect(FolderIconChoice(color: .red, emojiText: "🐢", imageFile: url).spec == .image(url))
    }
}

@MainActor @Suite struct FolderDecorationTests {
    private func item(_ url: URL) -> FileItem {
        FileItem(url: url, name: url.lastPathComponent, isDirectory: true, isPackage: false, isSymlink: false,
                 isHidden: false, size: nil, modified: nil, created: nil, contentTypeID: nil)
    }

    @Test func aCustomIconIsReadFromTheFolderAndGoesBackWhenRemoved() async throws {
        let dir = try FaultFixture.tempDir("hspace-icon")
        defer { FaultFixture.remove(dir) }
        _ = try await Engines.metadata.apply(.folderIcon(.emoji("🐢")), to: [dir])
        let folder = item(dir)
        let generic = Formatters.icon(for: folder)

        let custom = FileDecoration(folder, ItemMetadata(hasCustomIcon: true)).icon
        #expect(custom != nil)
        #expect(custom !== generic)
        #expect(FileDecoration(folder, nil).icon === generic)
    }

    @Test func filesKeepTheirIconPath() {
        let file = FileItem(url: URL(fileURLWithPath: "/x/a"), name: "a", isDirectory: false, isPackage: false,
                            isSymlink: false, isHidden: false, size: nil, modified: nil, created: nil, contentTypeID: nil)
        #expect(FileDecoration(file, nil).icon == nil)
    }
}
