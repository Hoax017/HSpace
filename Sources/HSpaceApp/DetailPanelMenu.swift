import AppKit

/// View menu entries of the side panel, and the window's side of them
extension MainWindowController {
    @objc func togglePreviewPanel(_ sender: Any?) {
        detail.setPreview(visible: !detail.previewVisible)
    }
}

@MainActor
enum DetailPanelMenu {
    static func addItems(to menu: NSMenu) {
        let preview = menu.addItem(withTitle: L10n.t("menu.togglePreviewPanel"),
                                   action: #selector(MainWindowController.togglePreviewPanel(_:)), keyEquivalent: "")
        KeyBindings.apply("togglePreviewPanel", to: preview)
    }

    /// nil = not a side panel entry, the caller decides
    static func validate(_ item: NSMenuItem, in window: MainWindowController) -> Bool? {
        switch item.action {
        case #selector(MainWindowController.togglePreviewPanel(_:)):
            item.state = window.detail.previewVisible ? .on : .off
            return true
        default:
            return nil
        }
    }
}
