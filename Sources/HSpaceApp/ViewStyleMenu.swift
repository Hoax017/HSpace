import AppKit
import ViewStyles

/// "View Options" in the View menu. It reads the store each time it opens.
@MainActor
final class ViewStyleMenu: NSObject, NSMenuDelegate {
    private static let shared = ViewStyleMenu()

    static func item() -> NSMenuItem {
        let item = NSMenuItem(title: L10n.t("menu.viewOptions"), action: nil, keyEquivalent: "")
        let menu = NSMenu(title: L10n.t("menu.viewOptions"))
        menu.delegate = shared
        item.submenu = menu
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: L10n.t("menu.rememberFolderView"),
                     action: #selector(MainWindowController.toggleFolderViewRule(_:)), keyEquivalent: "")
        menu.addItem(withTitle: L10n.t("menu.ruleIncludesSubfolders"),
                     action: #selector(MainWindowController.toggleRuleIncludesSubfolders(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let styles = ViewStylesHost.store.styles()
        for style in styles {
            let entry = menu.addItem(withTitle: style.name, action: #selector(MainWindowController.applyViewStyle(_:)), keyEquivalent: "")
            entry.representedObject = style.id
        }
        if !styles.isEmpty { menu.addItem(.separator()) }
        menu.addItem(withTitle: L10n.t("menu.saveViewStyle"),
                     action: #selector(MainWindowController.saveViewStyle(_:)), keyEquivalent: "")
        menu.addItem(withTitle: L10n.t("menu.manageViewStyles"),
                     action: #selector(MainWindowController.manageViewStyles(_:)), keyEquivalent: "")
    }

    /// nil = not an entry of this menu, the caller decides
    static func validate(_ item: NSMenuItem, in window: MainWindowController) -> Bool? {
        let pane = window.grid.activePane
        switch item.action {
        case #selector(MainWindowController.toggleFolderViewRule(_:)):
            item.state = pane.folderHasOwnRule ? .on : .off
            return true
        case #selector(MainWindowController.toggleRuleIncludesSubfolders(_:)):
            item.state = pane.folderRuleIncludesSubfolders ? .on : .off
            return pane.folderHasOwnRule
        default:
            return nil
        }
    }
}

extension MainWindowController {
    @objc func toggleFolderViewRule(_ sender: Any?) { grid.activePane.toggleFolderRule() }
    @objc func toggleRuleIncludesSubfolders(_ sender: Any?) { grid.activePane.toggleRuleIncludesSubfolders() }

    @objc func applyViewStyle(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let saved = ViewStylesHost.store.styles().first(where: { $0.id == id }) else { return }
        grid.activePane.applyStyle(saved.style)
        syncDeck()
    }

    @objc func saveViewStyle(_ sender: Any?) {
        guard let window else { return }
        let style = grid.activePane.currentStyle
        ViewStyleNamePrompt.ask(title: L10n.t("viewStyle.saveTitle"), initial: "", in: window) { name in
            do {
                try ViewStylesHost.store.saveStyle(named: name, style: style)
            } catch {
                ToolUI.showError(error.localizedDescription, in: window)
            }
        }
    }

    @objc func manageViewStyles(_ sender: Any?) {
        guard let window else { return }
        ViewStyleManagerSheet.present(store: ViewStylesHost.store, in: window)
    }
}

@MainActor
enum ViewStyleNamePrompt {
    static func ask(title: String, initial: String, in window: NSWindow, _ done: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: L10n.t("comment.save"))
        alert.addButton(withTitle: L10n.t("common.cancel"))
        let field = NSTextField(string: initial)
        field.placeholderString = L10n.t("viewStyle.namePlaceholder")
        field.setAccessibilityLabel(L10n.t("viewStyle.namePlaceholder"))
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { done(field.stringValue) }
        }
    }
}

/// The manager: saved styles and remembered folders, in one sheet
@MainActor
final class ViewStyleManagerSheet: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private enum Row {
        case style(SavedViewStyle)
        case folder(String, FolderViewRule)
    }

    private static var live: ViewStyleManagerSheet?

    private let store: any ViewStyleStoring
    private let host: NSWindow
    private let panel = ToolUI.panel(width: 520, height: 360)
    private var table: NSTableView!
    private var rows: [Row] = []
    private lazy var renameButton = ToolUI.button(L10n.t("viewStyle.rename"), target: self, action: #selector(renameTapped))
    private lazy var removeButton = ToolUI.button(L10n.t("viewStyle.remove"), target: self, action: #selector(removeTapped))

    static func present(store: any ViewStyleStoring, in host: NSWindow) {
        guard live == nil, host.attachedSheet == nil else { return }
        let sheet = ViewStyleManagerSheet(store: store, host: host)
        live = sheet
        host.beginSheet(sheet.panel) { _ in }
    }

    private init(store: any ViewStyleStoring, host: NSWindow) {
        self.store = store
        self.host = host
        super.init()
        let (scroll, table) = ToolUI.table(columns: [("name", L10n.t("viewStyle.column.name"), 340),
                                                     ("type", L10n.t("viewStyle.column.type"), 120)],
                                           source: self, height: 240)
        self.table = table
        let close = ToolUI.button(L10n.t("common.close"), target: self, action: #selector(closeTapped))
        close.keyEquivalent = "\u{1b}"
        ToolUI.fill(panel, with: [ToolUI.title(L10n.t("viewStyle.managerTitle")), scroll,
                                  ToolUI.buttonRow(leading: removeButton, [renameButton, close])])
        reload()
    }

    private func reload() {
        rows = store.styles().map(Row.style)
            + store.folders().sorted { $0.key < $1.key }.map { Row.folder($0.key, $0.value) }
        table.reloadData()
        syncButtons()
    }

    private func syncButtons() {
        let row = rows[safe: table.selectedRow]
        removeButton.isEnabled = row != nil
        if case .style = row { renameButton.isEnabled = true } else { renameButton.isEnabled = false }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let entry = rows[safe: row], let column = tableColumn?.identifier.rawValue else { return nil }
        let text: String
        switch (entry, column) {
        case (.style(let saved), "name"): text = saved.name
        case (.style, _): text = L10n.t("viewStyle.kind.style")
        case (.folder(let path, _), "name"): text = path
        case (.folder(_, let rule), _):
            text = L10n.t(rule.includeSubfolders ? "viewStyle.kind.folderAndBelow" : "viewStyle.kind.folder")
        }
        return ToolUI.cell(in: tableView, text: text)
    }

    func tableViewSelectionDidChange(_ notification: Notification) { syncButtons() }

    @objc private func renameTapped() {
        guard case .style(let saved)? = rows[safe: table.selectedRow] else { return }
        ViewStyleNamePrompt.ask(title: L10n.t("viewStyle.renameTitle"), initial: saved.name, in: panel) { [weak self] name in
            self?.attempt { try self?.store.renameStyle(saved.id, to: name) }
        }
    }

    /// A style is work the owner may want back, so it asks. A folder rule is one menu click to set again.
    @objc private func removeTapped() {
        switch rows[safe: table.selectedRow] {
        case .style(let saved):
            let alert = NSAlert()
            alert.messageText = L10n.f("viewStyle.deleteQuestion", saved.name)
            alert.addButton(withTitle: L10n.t("viewStyle.remove"))
            alert.addButton(withTitle: L10n.t("common.cancel"))
            alert.beginSheetModal(for: panel) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                MainActor.assumeIsolated { self?.attempt { try self?.store.deleteStyle(saved.id) } }
            }
        case .folder(let path, _):
            attempt { try store.removeRule(for: path) }
        case nil:
            break
        }
    }

    private func attempt(_ change: () throws -> Void) {
        do {
            try change()
        } catch {
            ToolUI.showError(error.localizedDescription, in: panel)
        }
        reload()
    }

    @objc private func closeTapped() {
        host.endSheet(panel)
        Self.live = nil
    }
}
