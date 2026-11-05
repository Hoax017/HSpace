import AppKit
import HSpaceContracts
import HSpaceTestSupport
import Testing
import ViewStyles
@testable import HSpaceApp

/// Serialized: the preference and the style store are app-wide
@MainActor @Suite(.serialized) struct IconLayoutWiringTests {
    private let wide = IconLayout(iconSize: 200, spacing: 16, label: .right)

    private func withApp(_ body: (URL) async throws -> Void) async throws {
        let dir = try FaultFixture.tempDir("hspace-iconlayout")
        let previousStore = ViewStylesHost.store
        let previousLayout = Preferences.iconLayout
        ViewStylesHost.store = ViewStyleStore(directory: dir.appendingPathComponent("support"))
        Preferences.iconLayout = .standard
        defer {
            ViewStylesHost.store = previousStore
            Preferences.iconLayout = previousLayout
            FaultFixture.remove(dir)
        }
        try await body(dir)
    }

    private func grid(_ dir: URL) -> FileIconGridViewController {
        let vc = FileIconGridViewController(model: DirectoryViewModel(directory: dir))
        _ = vc.view
        return vc
    }

    private func spacingItem(_ value: Int) -> NSMenuItem {
        let item = NSMenuItem()
        item.tag = value
        return item
    }

    private func labelItem(_ position: IconLabelPosition) -> NSMenuItem {
        let item = NSMenuItem()
        item.representedObject = position.rawValue
        return item
    }

    @Test func aChangeWithoutAFolderStyleGoesToThePreference() async throws {
        try await withApp { dir in
            let vc = grid(dir)
            vc.setIconSpacing(spacingItem(16))
            #expect(Preferences.iconLayout.spacing == 16)
            vc.setIconLabelPosition(labelItem(.right))
            #expect(Preferences.iconLayout.label == .right)
            #expect(vc.iconLayout.label == .right)
        }
    }

    @Test func aChangeUnderAFolderStyleLeavesThePreferenceAlone() async throws {
        try await withApp { dir in
            let vc = grid(dir)
            vc.setFolderLayout(wide)
            vc.setIconSpacing(spacingItem(4))
            #expect(vc.iconLayout.spacing == 4)
            #expect(Preferences.iconLayout == .standard)
            vc.setFolderLayout(nil)
            #expect(vc.iconLayout == .standard)
        }
    }

    @Test func theItemFollowsTheLayout() async throws {
        try await withApp { dir in
            let vc = grid(dir)
            vc.setFolderLayout(wide)
            let flow = try #require(vc.testFlowLayout)
            #expect(flow.itemSize.width == CGFloat(wide.itemSize.width))
            #expect(flow.minimumLineSpacing == 16)
        }
    }

    @Test func aRememberedFolderKeepsItsIconLayout() async throws {
        try await withApp { dir in
            let plain = dir.appendingPathComponent("plain")
            let styled = dir.appendingPathComponent("styled")
            try FaultFixture.write(to: plain.appendingPathComponent("a"))
            try FaultFixture.write(to: styled.appendingPathComponent("b"))
            let style = ViewStyle(viewMode: PaneViewMode.icons.rawValue, iconLayout: wide)
            try ViewStylesHost.store.setRule(FolderViewRule(style: style), for: styled.path)

            let pane = PaneViewController(directory: plain)
            _ = pane.view
            defer { pane.activeTab.model.stopWatching() }
            pane.navigate(to: styled)
            #expect(pane.activeTab.iconVC?.iconLayout == wide)

            pane.activeTab.iconVC?.setIconSpacing(spacingItem(24))
            #expect(ViewStylesHost.store.rule(for: styled.path)?.rule.style.iconLayout?.spacing == 24)

            pane.navigate(to: plain)
            pane.setViewMode(.icons)
            #expect(pane.activeTab.iconVC?.iconLayout == .standard)
        }
    }

    @Test func spacingsOfTheMenuAreAllAllowed() {
        for value in IconLayout.spacings {
            #expect(IconLayout(iconSize: 80, spacing: value, label: .bottom).spacing == value)
        }
    }

    @Test func aMenuEntryIsTickedForTheCurrentLayout() async throws {
        try await withApp { dir in
            let vc = grid(dir)
            let menu = NSMenu()
            IconOptionsMenu.addItems(to: menu, target: vc)
            let normal = try #require(menu.items.first { $0.tag == 8 })
            #expect(vc.validateMenuItem(normal))
            #expect(normal.state == .on)
        }
    }
}
