import AppKit
import ContextMenuLayout
import HSpaceContracts
import HSpaceKernel
import HSpaceTestSupport
import Testing
@testable import HSpaceApp

@MainActor @Suite struct ContextMenuCustomizationTests {
    private func item(_ name: String, in dir: URL, folder: Bool = false) -> FileItem {
        FileItem(url: dir.appendingPathComponent(name), name: name, isDirectory: folder, isPackage: false,
                 isSymlink: false, isHidden: false, size: 5, modified: nil, created: nil, contentTypeID: nil)
    }

    private func coordinator() -> FileOpsCoordinator {
        FileOpsCoordinator(kernel: OperationKernel(), grid: PaneGridController(initialDirectory: URL(fileURLWithPath: "/")))
    }

    /// A list view wired to a coordinator, so the metadata entries are in its menus too
    private func list(_ dir: URL, _ coordinator: FileOpsCoordinator) -> FileListViewController {
        let list = FileListViewController(model: DirectoryViewModel(directory: dir))
        list.coordinator = coordinator
        return list
    }

    private func sections(of menu: NSMenu) -> [[String]] {
        var result: [[String]] = [[]]
        for item in menu.items {
            if item.isSeparatorItem { result.append([]) } else { result[result.count - 1].append(item.identifier?.rawValue ?? "?") }
        }
        return result
    }

    private func fullMenus(_ body: (NSMenu, NSMenu) throws -> Void) throws {
        let dir = try FaultFixture.tempDir("hspace-ctxmenu")
        defer { FaultFixture.remove(dir) }
        let coordinator = coordinator()
        let target = list(dir, coordinator)
        let selection = [item("a.zip", in: dir), item("Folder", in: dir, folder: true)]
        let itemMenu = FileContextMenuBuilder.menu(selection: selection, directory: dir, target: target)
        let dirMenu = FileContextMenuBuilder.menu(selection: [], directory: dir, target: target)
        try body(itemMenu, dirMenu)
    }

    @Test func idsAreUniqueInEachMenu() {
        for kind in ContextMenuKind.allCases {
            let ids = ContextMenuCatalog.ids(kind).joined()
            #expect(Set(ids).count == ids.count, "\(kind)")
        }
    }

    @Test func everyTitleIsLocalized() throws {
        let strings = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/en.lproj/Localizable.strings"), encoding: .utf8)
        for kind in ContextMenuKind.allCases {
            #expect(strings.contains("\"\(kind.titleKey)\" ="))
            for entry in ContextMenuCatalog.sections(kind).joined() {
                #expect(strings.contains("\"\(entry.titleKey)\" ="), "\(entry.id)")
            }
        }
    }

    @Test func everyBuiltEntryIsInTheCatalogInItsSection() throws {
        try fullMenus { itemMenu, dirMenu in
            for (menu, kind) in [(itemMenu, ContextMenuKind.item), (dirMenu, .directory)] {
                let catalog = ContextMenuCatalog.ids(kind)
                let built = sections(of: menu)
                #expect(built.allSatisfy { !$0.isEmpty }, "\(kind): no empty section")
                for section in built {
                    let home = catalog.first { $0.contains(section[0]) }
                    #expect(home != nil, "\(kind): \(section[0]) is not in the catalog")
                    guard let home else { continue }
                    #expect(section == home.filter(section.contains), "\(kind): \(section) keeps its catalog section and order")
                }
            }
            // The menus built here show the metadata and archive entries, so the catalog is really exercised
            #expect(sections(of: itemMenu).joined().contains("tags"))
            #expect(sections(of: itemMenu).joined().contains("extract"))
            #expect(sections(of: dirMenu).joined().contains("filterByTag"))
        }
    }

    @Test func hiddenEntriesAndEmptiedGroupsLeaveTheMenu() throws {
        try fullMenus { itemMenu, _ in
            let settings = ContextMenuSettings(hidden: ["open", "openWith", "cut"])
            ContextMenuCustomization.apply(to: itemMenu, settings: settings)
            let ids = itemMenu.items.compactMap { $0.identifier?.rawValue }
            #expect(!ids.contains("open") && !ids.contains("openWith") && !ids.contains("cut"))
            #expect(itemMenu.items.first?.isSeparatorItem == false)
            #expect(itemMenu.items.last?.isSeparatorItem == false)
            #expect(!zip(itemMenu.items, itemMenu.items.dropFirst()).contains { $0.isSeparatorItem && $1.isSeparatorItem })
            #expect(sections(of: itemMenu).first?.first == "copy")
        }
    }

    @Test func reorderedEntriesKeepTheirActions() throws {
        try fullMenus { itemMenu, _ in
            let copy = try #require(itemMenu.items.first { $0.identifier?.rawValue == "copy" })
            var settings = ContextMenuSettings()
            settings.move("copyPath", by: -3, in: ContextMenuCatalog.ids(.item))
            ContextMenuCustomization.apply(to: itemMenu, settings: settings)
            #expect(sections(of: itemMenu)[1] == ["copyPath", "copy", "cut", "paste"])
            #expect(itemMenu.items.first { $0.identifier?.rawValue == "copy" } === copy)
            #expect(copy.action == #selector(FileListViewController.copyItems(_:)))
        }
    }

    @Test func anEntryWithoutAnIdStaysInItsGroup() {
        let menu = NSMenu()
        menu.addItem(FileContextMenuBuilder.tagged(NSMenuItem(title: "A", action: nil, keyEquivalent: ""), "a"))
        menu.addItem(NSMenuItem(title: "Plain", action: nil, keyEquivalent: ""))
        menu.addItem(FileContextMenuBuilder.tagged(NSMenuItem(title: "B", action: nil, keyEquivalent: ""), "b"))
        menu.addItem(.separator())
        menu.addItem(FileContextMenuBuilder.tagged(NSMenuItem(title: "C", action: nil, keyEquivalent: ""), "c"))
        ContextMenuCustomization.apply(to: menu, settings: ContextMenuSettings(hidden: ["c"], order: ["b", "a"]))
        #expect(menu.items.map(\.title) == ["B", "A", "Plain"])
    }

    @Test func theSettingsPageStoresAndResets() throws {
        let suite = "hspace-ctxmenu-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let page = ContextMenuSettingsPage(defaults: defaults)
        _ = page.makeView()
        page.setShown("cut", false)
        page.move("paste", by: -1)
        let keys = ContextMenuCustomization.defaultsKeys(.item)
        #expect(defaults.stringArray(forKey: keys.hidden) == ["cut"])
        #expect(ContextMenuCustomization.settings(.item, defaults: defaults).ordered(ContextMenuCatalog.ids(.item))[1]
            == ["copy", "paste", "cut", "copyPath"])
        #expect(page.rowTitles.contains(L10n.t("menu.paste")))

        page.select(.directory)
        #expect(page.settings.isDefault, "each menu has its own layout")
        page.select(.item)
        #expect(page.settings.isHidden("cut"))

        page.resetLayout(nil)
        #expect(defaults.object(forKey: keys.hidden) == nil)
        #expect(defaults.object(forKey: keys.order) == nil)
    }
}
