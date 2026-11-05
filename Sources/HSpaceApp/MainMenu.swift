import AppKit

/// Menu bar built entirely in code. Lists only commands implemented in the current milestone: no real feature, no UI element (spec section 6).
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        // App menu
        let appItem = main.addItem(withTitle: "HSpace", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: L10n.t("menu.about"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.t("menu.settings"), action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.t("menu.hide"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: L10n.t("menu.hideOthers"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: L10n.t("menu.showAll"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.t("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File
        let fileItem = main.addItem(withTitle: L10n.t("menu.file"), action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: L10n.t("menu.file"))
        fileItem.submenu = fileMenu
        fileMenu.addItem(withTitle: L10n.t("menu.newWindow"), action: #selector(AppDelegate.newWindow(_:)), keyEquivalent: "n")
        let newTabItem = fileMenu.addItem(withTitle: L10n.t("menu.newWorkspace"), action: #selector(MainWindowController.newWorkspaceTab(_:)), keyEquivalent: "")
        KeyBindings.apply("newTab", to: newTabItem)
        let nextWsItem = fileMenu.addItem(withTitle: L10n.t("menu.nextWorkspace"),
                                          action: #selector(MainWindowController.nextWorkspace(_:)), keyEquivalent: "")
        KeyBindings.apply("nextWorkspace", to: nextWsItem)
        let prevWsItem = fileMenu.addItem(withTitle: L10n.t("menu.prevWorkspace"),
                                          action: #selector(MainWindowController.previousWorkspace(_:)), keyEquivalent: "")
        KeyBindings.apply("prevWorkspace", to: prevWsItem)
        let newFolderItem = fileMenu.addItem(withTitle: L10n.t("menu.newFolder"),
                                             action: #selector(FileListViewController.newFolderHere(_:)), keyEquivalent: "")
        KeyBindings.apply("newFolder", to: newFolderItem)
        let newFileItem = fileMenu.addItem(withTitle: L10n.t("menu.newFile"),
                                           action: #selector(FileListViewController.newFileHere(_:)), keyEquivalent: "")
        KeyBindings.apply("newFile", to: newFileItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: L10n.t("menu.open"),
                         action: #selector(FileListViewController.openSelected(_:)), keyEquivalent: "o")
        let qlItem = fileMenu.addItem(withTitle: L10n.t("menu.quickLook"),
                         action: #selector(FileListViewController.toggleQuickLook(_:)), keyEquivalent: "")
        KeyBindings.apply("quickLook", to: qlItem)
        let infoItem = fileMenu.addItem(withTitle: L10n.t("menu.getInfo"),
                         action: #selector(FileListViewController.getInfo(_:)), keyEquivalent: "")
        KeyBindings.apply("getInfo", to: infoItem)
        fileMenu.addItem(withTitle: L10n.t("menu.rename"),
                         action: #selector(FileListViewController.renameSelected(_:)), keyEquivalent: "")
        let tagsItem = fileMenu.addItem(withTitle: L10n.t("menu.editTags"),
                                        action: #selector(FileListViewController.editTags(_:)), keyEquivalent: "")
        KeyBindings.apply("editTags", to: tagsItem)
        let commentItem = fileMenu.addItem(withTitle: L10n.t("menu.editComment"),
                                           action: #selector(FileListViewController.editComment(_:)), keyEquivalent: "")
        KeyBindings.apply("editComment", to: commentItem)
        let dupItem = fileMenu.addItem(withTitle: L10n.t("menu.duplicate"),
                         action: #selector(FileListViewController.duplicateItems(_:)), keyEquivalent: "")
        KeyBindings.apply("duplicate", to: dupItem)
        let trashItem = fileMenu.addItem(withTitle: L10n.t("menu.moveToTrash"),
                                         action: #selector(FileListViewController.moveToTrash(_:)), keyEquivalent: "")
        KeyBindings.apply("moveToTrash", to: trashItem)
        fileMenu.addItem(.separator())
        // F5 copy / F6 move to the other pane (QSpace muscle memory; defaults F5/F6, rebindable in settings)
        let f5 = fileMenu.addItem(withTitle: L10n.t("menu.copyToOtherPane"),
                                  action: #selector(FileListViewController.copyToOtherPane(_:)), keyEquivalent: "")
        KeyBindings.apply("copyToOtherPane", to: f5)
        let f6 = fileMenu.addItem(withTitle: L10n.t("menu.moveToOtherPane"),
                                  action: #selector(FileListViewController.moveToOtherPane(_:)), keyEquivalent: "")
        KeyBindings.apply("moveToOtherPane", to: f6)
        fileMenu.addItem(.separator())
        // Layered ⌘W close (I-21): routes to AppDelegate.closeTopmost; floating panels first, only main windows close a workspace tab
        let closeTabItem = fileMenu.addItem(withTitle: L10n.t("menu.closeWorkspace"), action: #selector(AppDelegate.closeTopmost(_:)), keyEquivalent: "")
        KeyBindings.apply("closeTab", to: closeTabItem)
        let closeWinItem = fileMenu.addItem(withTitle: L10n.t("menu.closeWindow"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeWinItem.keyEquivalentModifierMask = [.command, .shift]

        // Edit (standard text editing chain, used by the path field and rename)
        let editItem = main.addItem(withTitle: L10n.t("menu.edit"), action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: L10n.t("menu.edit"))
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: L10n.t("menu.undo"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: L10n.t("menu.redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L10n.t("menu.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L10n.t("menu.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L10n.t("menu.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let copyPathItem = editMenu.addItem(withTitle: L10n.t("menu.copyPath"),
                                            action: #selector(FileListViewController.copyPath(_:)), keyEquivalent: "")
        KeyBindings.apply("copyPath", to: copyPathItem)
        editMenu.addItem(withTitle: L10n.t("menu.selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // View
        let viewItem = main.addItem(withTitle: L10n.t("menu.view"), action: nil, keyEquivalent: "")
        let viewMenu = NSMenu(title: L10n.t("menu.view"))
        viewItem.submenu = viewMenu

        // View modes (M9: per pane; I-13 moved to the registry with defaults ⌥⌘1/2/3; validateMenuItem ticks the current mode)
        let modeSpecs: [(String, Selector, String, String)] = [
            ("menu.viewAsIcons", #selector(PaneViewController.viewAsIcons(_:)), "viewAsIcons", "square.grid.2x2"),
            ("menu.viewAsList", #selector(PaneViewController.viewAsList(_:)), "viewAsList", "list.bullet"),
            ("menu.viewAsColumns", #selector(PaneViewController.viewAsColumns(_:)), "viewAsColumns", "rectangle.split.3x1"),
        ]
        for (key, sel, bindingID, symbol) in modeSpecs {
            let item = viewMenu.addItem(withTitle: L10n.t(key), action: sel, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            KeyBindings.apply(bindingID, to: item)
        }
        viewMenu.addItem(.separator())

        // Layout submenu (default ⌃⌘1..5; M19 moved to the registry, rebindable in settings)
        let layoutItem = viewMenu.addItem(withTitle: L10n.t("menu.layout"), action: nil, keyEquivalent: "")
        let layoutMenu = NSMenu(title: L10n.t("menu.layout"))
        layoutItem.submenu = layoutMenu
        for (i, layout) in PaneLayout.allCases.enumerated() {
            let item = layoutMenu.addItem(withTitle: layout.localizedName,
                                          action: #selector(MainWindowController.applyLayout(_:)),
                                          keyEquivalent: "")
            KeyBindings.apply("layout\(i + 1)", to: item)
            item.tag = layout.rawValue
            item.image = NSImage(systemSymbolName: layout.symbolName, accessibilityDescription: nil)
        }
        viewMenu.addItem(.separator())
        let sidebarItem = viewMenu.addItem(withTitle: L10n.t("menu.toggleSidebar"),
                                           action: #selector(MainWindowController.toggleSidebar(_:)),
                                           keyEquivalent: "")
        KeyBindings.apply("toggleSidebar", to: sidebarItem)
        viewMenu.addItem(.separator())
        let hiddenItem = viewMenu.addItem(withTitle: L10n.t("menu.toggleHidden"),
                                          action: #selector(FileListViewController.toggleHiddenFiles(_:)),
                                          keyEquivalent: "")
        KeyBindings.apply("toggleHidden", to: hiddenItem)
        // Use Groups (M26): groups the list by year/month when sorted by date; validateMenuItem ticks the current state
        let groupingItem = viewMenu.addItem(withTitle: L10n.t("menu.toggleGrouping"),
                                            action: #selector(FileListViewController.toggleGrouping(_:)),
                                            keyEquivalent: "")
        KeyBindings.apply("toggleGrouping", to: groupingItem)
        let refreshItem = viewMenu.addItem(withTitle: L10n.t("menu.refresh"),
                         action: #selector(FileListViewController.refresh(_:)), keyEquivalent: "")
        KeyBindings.apply("refresh", to: refreshItem)

        // Go
        let goItem = main.addItem(withTitle: L10n.t("menu.go"), action: nil, keyEquivalent: "")
        let goMenu = NSMenu(title: L10n.t("menu.go"))
        goItem.submenu = goMenu
        let backItem = goMenu.addItem(withTitle: L10n.t("menu.back"),
                       action: #selector(PaneViewController.goBack(_:)), keyEquivalent: "")
        KeyBindings.apply("back", to: backItem)
        let fwdItem = goMenu.addItem(withTitle: L10n.t("menu.forward"),
                       action: #selector(PaneViewController.goForward(_:)), keyEquivalent: "")
        KeyBindings.apply("forward", to: fwdItem)
        let upItem = goMenu.addItem(withTitle: L10n.t("menu.goUp"),
                                    action: #selector(PaneViewController.goUpFolder(_:)), keyEquivalent: "")
        KeyBindings.apply("goUp", to: upItem)
        let downItem = goMenu.addItem(withTitle: L10n.t("menu.goDown"),
                                      action: #selector(PaneViewController.goDownFolder(_:)), keyEquivalent: "")
        KeyBindings.apply("goDown", to: downItem)
        goMenu.addItem(.separator())
        let trashNavItem = goMenu.addItem(withTitle: L10n.t("menu.goTrash"),
                                          action: #selector(PaneViewController.goTrash(_:)), keyEquivalent: "")
        KeyBindings.apply("goTrash", to: trashNavItem)
        let homeItem = goMenu.addItem(withTitle: L10n.t("menu.goHome"),
                                      action: #selector(PaneViewController.goHome(_:)), keyEquivalent: "h")
        homeItem.keyEquivalentModifierMask = [.command, .shift]
        let pathItem = goMenu.addItem(withTitle: L10n.t("menu.goToPath"),
                       action: #selector(PaneViewController.editPath(_:)), keyEquivalent: "")
        KeyBindings.apply("goToPath", to: pathItem)
        goMenu.addItem(.separator())
        // Focused search: default ⌘F current folder / ⇧⌘F global (rebindable in settings)
        let hereSearch = goMenu.addItem(withTitle: L10n.t("menu.searchHere"),
                       action: #selector(MainWindowController.showSearchHere(_:)), keyEquivalent: "")
        KeyBindings.apply("searchHere", to: hereSearch)
        let globalSearch = goMenu.addItem(withTitle: L10n.t("menu.searchGlobal"),
                                          action: #selector(MainWindowController.showSearchGlobal(_:)),
                                          keyEquivalent: "")
        KeyBindings.apply("searchGlobal", to: globalSearch)

        // Window
        let windowItem = main.addItem(withTitle: L10n.t("menu.window"), action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: L10n.t("menu.window"))
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: L10n.t("menu.minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: L10n.t("menu.zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        // Direct workspace digits ⌘1..9 (I-13; tag = workspace index, validate grays out items beyond the current count)
        for n in 1...9 {
            let item = windowMenu.addItem(withTitle: L10n.t("menu.gotoWorkspace\(n)"),
                                          action: #selector(MainWindowController.switchWorkspaceByNumber(_:)),
                                          keyEquivalent: "")
            item.tag = n - 1
            KeyBindings.apply("workspace\(n)", to: item)
        }
        NSApp.windowsMenu = windowMenu

        return main
    }

    // MARK: Self-test channel (I-62)

    /// Finds a menu item by action in the **real assembled** main menu tree (rather than re-creating the build logic,
    /// which could never catch "the item was built but never attached")
    /// Returns (menu item, title of its owning menu): answering only "this action exists somewhere in the tree" is not enough,
    /// since attaching it under any menu would pass; the caller must be able to verify it really sits in Go.
    static func uiTestMenuItem(for action: Selector) -> (item: NSMenuItem, ownerTitle: String)? {
        func find(_ menu: NSMenu) -> (NSMenuItem, String)? {
            for item in menu.items {
                if item.action == action { return (item, menu.title) }
                if let sub = item.submenu, let hit = find(sub) { return hit }
            }
            return nil
        }
        guard let main = NSApp.mainMenu else { return nil }
        return find(main)
    }
}
