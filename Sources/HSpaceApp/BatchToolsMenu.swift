import AppKit
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
        item.submenu = menu
        return item
    }

    /// nil = not a batch tool, the caller decides
    static func validate(_ item: NSMenuItem, in window: MainWindowController) -> Bool? {
        guard item.action == #selector(MainWindowController.showBatchRename(_:)) else { return nil }
        return window.renamableSelection != nil
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
        BatchRenameSheetController.present(items: items, coordinator: coordinator, in: window)
    }
}
