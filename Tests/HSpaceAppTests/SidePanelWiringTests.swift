import AppKit
import HSpaceContracts
import HSpaceTestSupport
import SidePanel
import Testing
@testable import HSpaceApp

@MainActor @Suite struct SidePanelWiringTests {
    private func item(_ name: String, in dir: URL) -> FileItem {
        FileItem(url: dir.appendingPathComponent(name), name: name, isDirectory: false, isPackage: false,
                 isSymlink: false, isHidden: false, size: 5, modified: nil, created: nil, contentTypeID: nil)
    }

    @Test func everyActionWorksInEveryViewMode() {
        for action in PanelAction.all {
            #expect(FileListViewController.instancesRespond(to: action.selector), "\(action.id) in list")
            #expect(FileIconGridViewController.instancesRespond(to: action.selector), "\(action.id) in icons")
            #expect(FileColumnViewController.instancesRespond(to: action.selector), "\(action.id) in columns")
        }
    }

    @Test func actionIDsAreUniqueAndTitled() {
        let ids = PanelAction.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(PanelAction.defaultIDs.allSatisfy { PanelAction.action($0) != nil })
    }

    @Test func aNameShowsForOneItemAndACountForSeveral() throws {
        let dir = try FaultFixture.tempDir("hspace-sidepanel")
        defer { FaultFixture.remove(dir) }
        try FaultFixture.write(to: dir.appendingPathComponent("a.txt"))
        let section = PreviewSectionView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        defer { section.close() }

        section.show(PreviewSubject(selection: [item("a.txt", in: dir)]))
        #expect(section.testName == "a.txt")
        #expect(section.testMessage.isEmpty)

        section.show(PreviewSubject(selection: [item("a.txt", in: dir), item("b.txt", in: dir)]))
        #expect(section.testName.isEmpty)
        #expect(section.testMessage == PreviewSectionView.summary(count: 2, folders: 0, size: Formatters.size.string(fromByteCount: 10)))

        section.show(.nothing)
        #expect(section.testMessage == L10n.t("panel.preview.nothing"))
    }

    @Test func aSizeOfFilesAloneSaysSoWhenFoldersAreSelected() {
        #expect(PreviewSectionView.summary(count: 2, folders: 0, size: nil) == L10n.f("panel.preview.count", 2))
        #expect(PreviewSectionView.summary(count: 2, folders: 1, size: "3 KB") == L10n.f("panel.preview.countFilesSize", 2, "3 KB"))
        #expect(PreviewSectionView.summary(count: 2, folders: 0, size: "3 KB") == L10n.f("panel.preview.countSize", 2, "3 KB"))
    }

    @Test func buttonsWrapToTheWidth() {
        #expect(ActionFlowView.perRow(width: 200) == 7)
        #expect(ActionFlowView.perRow(width: 8) == 1)
        #expect(ActionFlowView.height(count: 0, width: 200) == 0)
        #expect(ActionFlowView.height(count: 7, width: 200) == 24)
        #expect(ActionFlowView.height(count: 8, width: 200) == 52)
    }

    @Test func aHiddenPanelTakesNoRoom() {
        let wasVisible = Preferences.previewPanelVisible
        defer { Preferences.previewPanelVisible = wasVisible }
        let detail = DetailPanelController()
        defer { detail.teardown() }
        detail.setPreview(visible: false)
        _ = detail.view
        #expect(detail.view.constraints.contains { $0.firstAttribute == .width && $0.constant == 0 })
        detail.setPreview(visible: true)
        #expect(detail.view.constraints.contains { $0.firstAttribute == .width && $0.constant >= SidePanelWidth.minimum })
    }
}
