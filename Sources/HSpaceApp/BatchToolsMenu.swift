import AppKit
import BatchRename
import HSpaceContracts

/// The "Batch Tools" submenu, shared by the File menu and the item context menu.
/// Actions have no target: they travel the responder chain to MainWindowController, which knows the active pane in any view mode.
@MainActor
enum BatchToolsMenu {
    static func item() -> NSMenuItem {
        let item = NSMenuItem(title: L10n.t("menu.batchTools"), action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: nil)
        let menu = NSMenu(title: L10n.t("menu.batchTools"))
        let rename = menu.addItem(withTitle: L10n.t("menu.batchRename"),
                                  action: #selector(MainWindowController.showBatchRename(_:)), keyEquivalent: "")
        KeyBindings.apply("batchRename", to: rename)
        let quick = menu.addItem(withTitle: L10n.t("menu.quickRename"),
                                 action: #selector(MainWindowController.showQuickRename(_:)), keyEquivalent: "")
        KeyBindings.apply("quickRename", to: quick)
        menu.addItem(withTitle: L10n.t("menu.renameLog"),
                     action: #selector(MainWindowController.showRenameLog(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let pattern = menu.addItem(withTitle: L10n.t("menu.selectByPattern"),
                                   action: #selector(MainWindowController.showSelectByPattern(_:)), keyEquivalent: "")
        KeyBindings.apply("selectByPattern", to: pattern)
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.t("menu.fileHash"),
                     action: #selector(MainWindowController.showFileHash(_:)), keyEquivalent: "")
        menu.addItem(withTitle: L10n.t("menu.imageConvert"),
                     action: #selector(MainWindowController.showImageConvert(_:)), keyEquivalent: "")
        item.submenu = menu
        return item
    }

    /// nil = not a batch tool, the caller decides
    static func validate(_ item: NSMenuItem, in window: MainWindowController) -> Bool? {
        switch item.action {
        case #selector(MainWindowController.showBatchRename(_:)):
            return window.renamableSelection != nil
        case #selector(MainWindowController.showQuickRename(_:)):
            return (window.renamableSelection?.count ?? .max) <= QuickRenameSheetController.itemLimit
        case #selector(MainWindowController.showFileHash(_:)):
            return !window.grid.activePane.toolSelection.isEmpty
        case #selector(MainWindowController.showImageConvert(_:)):
            return !window.selectedImages.isEmpty
        default:
            return nil
        }
    }
}

extension PaneViewController {
    /// The selection in whichever view mode this pane is showing
    var toolSelection: [FileItem] {
        switch activeTab.viewMode {
        case .list: return activeTab.listVC.selectedItems
        case .icons: return activeTab.iconVC?.selectedItems ?? []
        case .columns: return activeTab.columnVC?.selectedItems ?? []
        }
    }

    /// The column the keyboard is in, whose items are "this folder" in column view
    private var toolColumn: ColumnUnit? {
        guard let view = activeTab.columnVC else { return nil }
        return view.columns.last { $0.directory == view.currentDirectory }
    }

    /// Everything shown in the current folder, in order
    var toolItems: [FileItem] {
        activeTab.viewMode == .columns ? toolColumn?.items ?? [] : activeTab.model.items
    }

    /// Replaces the selection in whichever view mode this pane is showing
    func applyToolSelection(_ urls: [URL]) {
        switch activeTab.viewMode {
        case .list:
            activeTab.listVC.select(urls: urls)
        case .icons:
            activeTab.iconVC?.select(urls: urls)
        case .columns:
            guard let column = toolColumn else { return }
            let wanted = Set(urls)
            let rows = IndexSet(column.items.indices.filter { wanted.contains(column.items[$0].url) })
            column.tableView.selectRowIndexes(rows, byExtendingSelection: false)
        }
    }
}

extension MainWindowController {
    /// Items a name-changing tool may touch. The Trash is left out: its names are what Put Back finds items by.
    var renamableSelection: [FileItem]? {
        let selection = grid.activePane.toolSelection
        guard !selection.isEmpty, !selection.contains(where: { TrashLocation.isInsideTrash($0.url) }) else { return nil }
        return selection
    }

    @objc func showBatchRename(_ sender: Any?) {
        guard let items = renamableSelection, let window else { NSSound.beep(); return }
        BatchRenameSheetController.present(items: items, ops: renameOps, store: renameStore, in: window)
    }

    @objc func showQuickRename(_ sender: Any?) {
        guard let items = renamableSelection, items.count <= QuickRenameSheetController.itemLimit, let window else {
            NSSound.beep()
            return
        }
        QuickRenameSheetController.present(items: items, ops: renameOps, in: window)
    }

    @objc func showFileHash(_ sender: Any?) {
        let files = grid.activePane.toolSelection.map(\.url)
        guard !files.isEmpty, let window else { NSSound.beep(); return }
        FileHashSheetController.present(files: files, in: window)
    }

    var selectedImages: [URL] {
        grid.activePane.toolSelection.filter(ImageConvertModel.isImage).map(\.url)
    }

    @objc func showImageConvert(_ sender: Any?) {
        let images = selectedImages
        guard !images.isEmpty, let window else { NSSound.beep(); return }
        ImageConvertSheetController.present(sources: images, coordinator: coordinator, in: window)
    }

    @objc func showSelectByPattern(_ sender: Any?) {
        guard let window else { return }
        let pane = grid.activePane
        SelectByPatternSheetController.present(items: pane.toolItems, selected: pane.toolSelection, in: window) { [weak pane] urls in
            pane?.applyToolSelection(urls)
        }
    }

    @objc func showRenameLog(_ sender: Any?) {
        guard let window, let store = renameStore else { NSSound.beep(); return }
        RenameLogSheetController.present(ops: renameOps, store: store, in: window)
    }

    var renameStore: RenameStore? { (NSApp.delegate as? AppDelegate)?.renameStore }
    var renameOps: BatchRenameOps { BatchRenameOps(coordinator: coordinator, store: renameStore) }
}
