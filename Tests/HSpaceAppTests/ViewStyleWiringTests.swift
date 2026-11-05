import AppKit
import HSpaceContracts
import HSpaceTestSupport
import Testing
import ViewStyles
@testable import HSpaceApp

/// Serialized: the store is app-wide
@MainActor @Suite(.serialized) struct ViewStyleWiringTests {
    private struct Fixture {
        let dir: URL
        let plain: URL
        let styled: URL
        let store: ViewStyleStore
        let previous: any ViewStyleStoring
        let pane: PaneViewController
    }

    private func setup() throws -> Fixture {
        let dir = try FaultFixture.tempDir("hspace-stylewiring")
        let plain = dir.appendingPathComponent("plain")
        let styled = dir.appendingPathComponent("styled")
        try FaultFixture.write(to: plain.appendingPathComponent("a"))
        try FaultFixture.write(to: styled.appendingPathComponent("sub/b"))
        let store = ViewStyleStore(directory: dir.appendingPathComponent("support"))
        let previous = ViewStylesHost.store
        ViewStylesHost.store = store
        let pane = PaneViewController(directory: plain)
        _ = pane.view
        return Fixture(dir: dir, plain: plain, styled: styled, store: store, previous: previous, pane: pane)
    }

    private func finish(_ fixture: Fixture) {
        ViewStylesHost.store = fixture.previous
        fixture.pane.activeTab.model.stopWatching()
        FaultFixture.remove(fixture.dir)
    }

    private let iconsBySize = ViewStyle(viewMode: PaneViewMode.icons.rawValue, sortKey: "size", sortAscending: false, includeHidden: true)

    @Test func enteringARememberedFolderUsesItsViewAndLeavingGivesThePanesBack() throws {
        let f = try setup()
        defer { finish(f) }
        let before = f.pane.currentStyle
        try f.store.setRule(FolderViewRule(style: iconsBySize), for: f.styled.path)

        f.pane.navigate(to: f.styled)
        #expect(f.pane.currentStyle == iconsBySize)

        f.pane.navigate(to: f.plain)
        #expect(f.pane.currentStyle == before)
    }

    @Test func goingBackWorksTheSame() throws {
        let f = try setup()
        defer { finish(f) }
        let before = f.pane.currentStyle
        try f.store.setRule(FolderViewRule(style: iconsBySize), for: f.styled.path)
        f.pane.navigate(to: f.styled)
        f.pane.goBack(nil)
        #expect(f.pane.currentStyle == before)
        f.pane.goForward(nil)
        #expect(f.pane.currentStyle == iconsBySize)
    }

    @Test func subfoldersFollowWhenTheRuleSaysSo() throws {
        let f = try setup()
        defer { finish(f) }
        try f.store.setRule(FolderViewRule(style: iconsBySize, includeSubfolders: true), for: f.styled.path)
        f.pane.navigate(to: f.styled.appendingPathComponent("sub"))
        #expect(f.pane.currentStyle == iconsBySize)
    }

    @Test func changingTheViewUpdatesARememberedFolder() throws {
        let f = try setup()
        defer { finish(f) }
        try f.store.setRule(FolderViewRule(style: iconsBySize), for: f.styled.path)
        f.pane.navigate(to: f.styled)
        f.pane.setViewMode(.list)
        #expect(f.store.rule(for: f.styled.path)?.rule.style.viewMode == PaneViewMode.list.rawValue)
        f.pane.activeTab.model.includeHidden = false
        #expect(f.store.rule(for: f.styled.path)?.rule.style.includeHidden == false)
    }

    @Test func changingTheViewOfAnInheritingFolderLeavesTheParentsRule() throws {
        let f = try setup()
        defer { finish(f) }
        try f.store.setRule(FolderViewRule(style: iconsBySize, includeSubfolders: true), for: f.styled.path)
        f.pane.navigate(to: f.styled.appendingPathComponent("sub"))
        f.pane.setViewMode(.list)
        #expect(f.store.rule(for: f.styled.path)?.rule.style == iconsBySize)
    }

    @Test func aFolderWithoutARuleIsNotTouched() throws {
        let f = try setup()
        defer { finish(f) }
        f.pane.setViewMode(.icons)
        #expect(f.store.folders().isEmpty)
    }

    @Test func rememberingAndForgettingFromTheMenu() throws {
        let f = try setup()
        defer { finish(f) }
        f.pane.toggleFolderRule()
        #expect(f.pane.folderHasOwnRule)
        f.pane.toggleRuleIncludesSubfolders()
        #expect(f.pane.folderRuleIncludesSubfolders)
        f.pane.toggleFolderRule()
        #expect(!f.pane.folderHasOwnRule)
    }

    @Test func applyingAStyleChangesTheViewNow() throws {
        let f = try setup()
        defer { finish(f) }
        f.pane.applyStyle(iconsBySize)
        #expect(f.pane.currentStyle == iconsBySize)
    }

    @Test func aPaneNotYetOnScreenTakesTheModeToo() throws {
        let f = try setup()
        defer { finish(f) }
        try f.store.setRule(FolderViewRule(style: iconsBySize), for: f.styled.path)
        let hidden = PaneViewController(directory: f.plain)
        hidden.navigate(to: f.styled)
        #expect(hidden.activeTab.viewMode == .icons)
        hidden.activeTab.model.stopWatching()
    }
}
