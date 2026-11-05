import Foundation
import HSpaceContracts
import SidePanel
import Testing

@Suite struct PreviewSubjectTests {
    private func item(_ name: String, folder: Bool = false, package: Bool = false, size: Int64? = nil) -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/x/\(name)"), name: name, isDirectory: folder, isPackage: package,
                 isSymlink: false, isHidden: false, size: size, modified: nil, created: nil, contentTypeID: nil)
    }

    @Test func noSelectionIsNothing() {
        #expect(PreviewSubject(selection: []) == .nothing)
    }

    @Test func oneItemIsThatItem() {
        #expect(PreviewSubject(selection: [item("a.txt", size: 3)]) == .item(url: URL(fileURLWithPath: "/x/a.txt"), name: "a.txt"))
    }

    @Test func severalAddUpFilesAndCountRealFolders() {
        let subject = PreviewSubject(selection: [item("a", size: 3), item("b", folder: true),
                                                 item("c.app", folder: true, package: true, size: 4)])
        #expect(subject == .several(count: 3, folders: 1, knownBytes: 7))
    }
}

@Suite struct PanelActionListTests {
    private let known = ["open", "copy", "trash", "info"]

    @Test func aNewOwnerGetsTheDefaultsAndSeesTheRest() {
        let list = PanelActionList(stored: nil, known: known, defaults: ["trash", "open"])
        #expect(list.enabled == ["trash", "open"])
        #expect(list.all == ["trash", "open", "copy", "info"])
    }

    @Test func anEmptyChoiceStaysEmpty() {
        #expect(PanelActionList(stored: [], known: known, defaults: ["open"]).enabled.isEmpty)
    }

    @Test func aStoredListLosesUnknownAndRepeatedIds() {
        let list = PanelActionList(stored: ["gone", "copy", "copy", "open"], known: known, defaults: [])
        #expect(list.enabled == ["copy", "open"])
        #expect(list.all == ["copy", "open", "trash", "info"])
    }

    @Test func turningOnAndOffKeepsThePlace() {
        var list = PanelActionList(stored: ["open", "copy"], known: known, defaults: [])
        list.set("open", enabled: false)
        #expect(list.enabled == ["copy"])
        #expect(list.all == ["open", "copy", "trash", "info"])
        list.set("open", enabled: true)
        #expect(list.enabled == ["open", "copy"])
    }

    @Test func anUnknownIdChangesNothing() {
        var list = PanelActionList(stored: ["open"], known: known, defaults: [])
        let before = list
        list.set("gone", enabled: true)
        list.move("gone", by: 1)
        #expect(list == before)
    }

    @Test func movingStopsAtTheEnds() {
        var list = PanelActionList(stored: ["open", "copy"], known: known, defaults: [])
        list.move("open", by: 1)
        #expect(list.enabled == ["copy", "open"])
        list.move("copy", by: -5)
        #expect(list.all.first == "copy")
        list.move("info", by: 5)
        #expect(list.all.last == "info")
    }
}

@Suite struct SidePanelWidthTests {
    @Test func widthStaysInBounds() {
        #expect(SidePanelWidth.clamped(10) == SidePanelWidth.minimum)
        #expect(SidePanelWidth.clamped(9000) == SidePanelWidth.maximum)
        #expect(SidePanelWidth.clamped(300) == 300)
        #expect(SidePanelWidth.clamped(.nan) == SidePanelWidth.standard)
    }
}
