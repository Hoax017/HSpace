import AppKit
import FileTemplates
import HSpaceContracts

extension FileOpsCoordinator {
    /// Copies a template in under its expanded, free name, and offers that name for editing.
    func newItem(from template: FileTemplate, in directory: URL, revealIn list: FileRevealTarget?,
                 onComplete: (@MainActor (OperationReceipt?) -> Void)? = nil) {
        guard !Self.isTrashDestination(directory) else {
            Toast.show(L10n.t("toast.notIntoTrash"), in: grid?.view.window)
            onComplete?(nil)
            return
        }
        let spec = OperationSpec(kind: .copy, sources: [template.url], destination: directory,
                                 newName: TemplateLibrary.targetName(for: template, in: directory))
        submit(spec) { receipt in
            if let url = receipt?.createdURLs.first { list?.prepareReveal(url, rename: true) }
            onComplete?(receipt)
        }
    }
}

/// "New from Template", shared by the File menu and the context menus. It reads the folder each time it opens, so
/// a template dropped there in Finder is there at once, and nothing watches the folder in between.
@MainActor
final class TemplateMenu: NSObject, NSMenuDelegate {
    private static let shared = TemplateMenu()

    static var library: TemplateLibrary {
        TemplateLibrary(folder: AppDelegate.supportDirectory.appendingPathComponent("Templates", isDirectory: true))
    }

    static func item() -> NSMenuItem {
        let item = NSMenuItem(title: L10n.t("menu.newFromTemplate"), action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        let menu = NSMenu(title: L10n.t("menu.newFromTemplate"))
        menu.delegate = shared
        item.submenu = menu
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        do {
            let templates = try Self.library.templates()
            for template in templates {
                let entry = menu.addItem(withTitle: template.displayName(),
                                         action: #selector(MainWindowController.newFromTemplate(_:)), keyEquivalent: "")
                entry.representedObject = template
                entry.image = NSWorkspace.shared.icon(forFile: template.url.path)
                entry.image?.size = NSSize(width: 16, height: 16)
            }
            if templates.isEmpty { addNote(L10n.t("templates.none"), to: menu) }
        } catch {
            addNote(error.localizedDescription, to: menu)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.t("menu.saveAsTemplate"),
                     action: #selector(MainWindowController.saveAsTemplate(_:)), keyEquivalent: "")
        menu.addItem(withTitle: L10n.t("menu.openTemplates"),
                     action: #selector(MainWindowController.openTemplatesFolder(_:)), keyEquivalent: "")
    }

    private func addNote(_ text: String, to menu: NSMenu) {
        let note = menu.addItem(withTitle: text, action: nil, keyEquivalent: "")
        note.isEnabled = false
    }

    /// nil = not a template entry, the caller decides
    static func validate(_ item: NSMenuItem, in window: MainWindowController) -> Bool? {
        switch item.action {
        case #selector(MainWindowController.newFromTemplate(_:)):
            return !TrashLocation.isInsideTrash(window.grid.activePane.activeTab.browser.current)
        case #selector(MainWindowController.saveAsTemplate(_:)):
            return !window.grid.activePane.toolSelection.isEmpty
        default:
            return nil
        }
    }
}

extension PaneViewController {
    /// Where a new item should be selected. Column view has no such place, as for New File.
    var revealTarget: FileRevealTarget? {
        switch activeTab.viewMode {
        case .list: activeTab.listVC
        case .icons: activeTab.iconVC
        case .columns: nil
        }
    }
}

extension MainWindowController {
    @objc func newFromTemplate(_ sender: NSMenuItem) {
        guard let template = sender.representedObject as? FileTemplate else { return }
        let pane = grid.activePane
        coordinator.newItem(from: template, in: pane.activeTab.browser.current, revealIn: pane.revealTarget)
    }

    @objc func saveAsTemplate(_ sender: Any?) {
        let selection = grid.activePane.toolSelection.map(\.url)
        guard !selection.isEmpty else { NSSound.beep(); return }
        do {
            let library = TemplateMenu.library
            try library.prepareFolder()
            coordinator.transfer(urls: selection, into: library.folder, move: false)
        } catch {
            ToolUI.showError(error.localizedDescription, in: window)
        }
    }

    @objc func openTemplatesFolder(_ sender: Any?) {
        do {
            let library = TemplateMenu.library
            try library.prepareFolder()
            grid.activePane.navigate(to: library.folder)
        } catch {
            ToolUI.showError(error.localizedDescription, in: window)
        }
    }
}
