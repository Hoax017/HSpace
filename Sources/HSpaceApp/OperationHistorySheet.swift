import AppKit
import OperationHistory

/// The operation history: what was done, oldest actions included, and an Undo that works across launches.
@MainActor
final class OperationHistorySheetController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static var live: OperationHistorySheetController?

    private let coordinator: FileOpsCoordinator
    private let store: HistoryStore
    private let host: NSWindow
    private let panel = ToolUI.panel(width: 640, height: 400)
    private var table: NSTableView!
    private(set) var groups: [HistoryGroup] = []
    private lazy var undoButton = ToolUI.button(L10n.t("history.undo"), target: self, action: #selector(undoTapped))
    private lazy var clearButton = ToolUI.button(L10n.t("history.clear"), target: self, action: #selector(clearTapped))
    private let note = ToolUI.label()
    private var isUndoing = false

    static func present(coordinator: FileOpsCoordinator, store: HistoryStore, in host: NSWindow) {
        guard live == nil, host.attachedSheet == nil else { return }
        let sheet = OperationHistorySheetController(coordinator: coordinator, store: store, host: host)
        live = sheet
        host.beginSheet(sheet.panel) { _ in }
        Task { await sheet.reload() }
    }

    init(coordinator: FileOpsCoordinator, store: HistoryStore, host: NSWindow) {
        self.coordinator = coordinator
        self.store = store
        self.host = host
        super.init()
        let (scroll, table) = ToolUI.table(columns: [
            ("date", L10n.t("history.column.date"), 140),
            ("action", L10n.t("history.column.action"), 120),
            ("items", L10n.t("history.column.items"), 240),
            ("state", L10n.t("history.column.state"), 100),
        ], source: self, height: 280)
        self.table = table
        let close = ToolUI.button(L10n.t("common.close"), target: self, action: #selector(closeTapped))
        close.keyEquivalent = "\u{1b}"
        undoButton.isEnabled = false
        ToolUI.fill(panel, with: [ToolUI.title(L10n.t("history.title")), scroll, note,
                                  ToolUI.buttonRow(leading: clearButton, [close, undoButton])])
    }

    func reload() async {
        groups = await store.groups()
        ProblemAlert.show(await store.takeProblem())
        table.reloadData()
        clearButton.isEnabled = !groups.isEmpty
        tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
    }

    private var selected: HistoryGroup? { groups[safe: table.selectedRow] }

    func numberOfRows(in tableView: NSTableView) -> Int { groups.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let group = groups[safe: row], let column = tableColumn?.identifier.rawValue else { return nil }
        let text: String
        switch column {
        case "date": text = DateFormatter.localizedString(from: group.date, dateStyle: .short, timeStyle: .short)
        case "action": text = group.title ?? L10n.t("tasks.kind.\(group.entries.first?.kind ?? "copy")")
        case "items": text = Self.itemsText(group)
        default: text = Self.stateText(group)
        }
        return ToolUI.cell(in: tableView, text: text, color: column == "state" && group.failure != nil ? .systemRed : .labelColor)
    }

    private static func itemsText(_ group: HistoryGroup) -> String {
        let names = group.entries.flatMap(\.names)
        guard let first = names.first else { return "" }
        return group.itemCount > 1 ? L10n.f("history.itemsMore", first, group.itemCount - 1) : first
    }

    private static func stateText(_ group: HistoryGroup) -> String {
        if group.isUndone { return L10n.t("history.state.undone") }
        if group.failure != nil { return L10n.t("history.state.failed") }
        if group.wasCancelled { return L10n.t("history.state.cancelled") }
        return L10n.t(group.canUndo ? "history.state.done" : "history.state.final")
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        undoButton.isEnabled = !isUndoing && selected?.canUndo == true
        note.stringValue = selected?.failure ?? ""
    }

    @objc private func undoTapped() {
        guard let group = selected, !isUndoing else { return }
        isUndoing = true
        undoButton.isEnabled = false
        Task {
            let result = await coordinator.undoHistory(group)
            isUndoing = false
            note.stringValue = Self.message(for: result)
            await reload()
            note.stringValue = Self.message(for: result)
        }
    }

    private static func message(for result: HistoryUndoResult) -> String {
        switch result {
        case .undone(let leftInPlace):
            return leftInPlace == 0 ? L10n.t("history.undone") : L10n.f("history.undoneLeftInPlace", leftInPlace)
        case .stopped: return L10n.t("history.stopped")
        case .refused(let blockers):
            switch blockers.first {
            case .missing(let path): return L10n.f("history.refused.missing", blockers.count, path)
            case .occupied(let path): return L10n.f("history.refused.occupied", blockers.count, path)
            case nil: return ""
            }
        }
    }

    @objc private func clearTapped() {
        let alert = NSAlert()
        alert.messageText = L10n.t("history.clear.title")
        alert.informativeText = L10n.t("history.clear.body")
        alert.addButton(withTitle: L10n.t("common.cancel"))
        alert.addButton(withTitle: L10n.t("history.clear"))
        alert.beginSheetModal(for: panel) { [self] response in
            guard response == .alertSecondButtonReturn else { return }
            Task {
                await store.clear()
                await reload()
            }
        }
    }

    @objc private func closeTapped() {
        host.endSheet(panel)
        Self.live = nil
    }
}

extension MainWindowController {
    @objc func showOperationHistory(_ sender: Any?) {
        guard let window, let store = (NSApp.delegate as? AppDelegate)?.historyStore else { NSSound.beep(); return }
        OperationHistorySheetController.present(coordinator: coordinator, store: store, in: window)
    }
}
