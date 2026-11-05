import AppKit
import BatchRename

/// The rename log: every batch with what it did, and an Undo that works across launches.
@MainActor
final class RenameLogSheetController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static var live: RenameLogSheetController?

    private let ops: BatchRenameOps
    private let store: RenameStore
    private let host: NSWindow
    private let panel = ToolUI.panel(width: 640, height: 400)
    private var table: NSTableView!
    private(set) var entries: [RenameLogEntry] = []
    private lazy var undoButton = ToolUI.button(L10n.t("renameLog.undo"), target: self, action: #selector(undoTapped))

    static func present(ops: BatchRenameOps, store: RenameStore, in host: NSWindow) {
        guard live == nil, host.attachedSheet == nil else { return }
        let sheet = RenameLogSheetController(ops: ops, store: store, host: host)
        live = sheet
        host.beginSheet(sheet.panel) { _ in }
        Task { await sheet.reload() }
    }

    init(ops: BatchRenameOps, store: RenameStore, host: NSWindow) {
        self.ops = ops
        self.store = store
        self.host = host
        super.init()
        let (scroll, table) = ToolUI.table(columns: [
            ("date", L10n.t("renameLog.column.date"), 140),
            ("count", L10n.t("renameLog.column.items"), 60),
            ("example", L10n.t("renameLog.column.example"), 280),
            ("state", L10n.t("renameLog.column.state"), 100),
        ], source: self, height: 280)
        self.table = table
        let close = ToolUI.button(L10n.t("common.close"), target: self, action: #selector(closeTapped))
        close.keyEquivalent = "\u{1b}"
        undoButton.isEnabled = false
        ToolUI.fill(panel, with: [ToolUI.title(L10n.t("renameLog.title")), scroll, ToolUI.buttonRow([close, undoButton])])
    }

    func reload() async {
        entries = await store.log()
        ProblemAlert.show(await store.takeProblem())
        table.reloadData()
        tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
    }

    private var selected: RenameLogEntry? { entries[safe: table.selectedRow] }

    func tableViewSelectionDidChange(_ notification: Notification) {
        undoButton.isEnabled = selected?.isReversed == false
    }

    @objc private func undoTapped() {
        guard let entry = selected, !entry.isReversed else { return }
        undoButton.isEnabled = false
        Task {
            await ops.undo(entry)
            await reload()
        }
    }

    @objc private func closeTapped() {
        host.endSheet(panel)
        panel.orderOut(nil)
        Self.live = nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "date":
            text = DateFormatter.localizedString(from: entry.journal.date, dateStyle: .short, timeStyle: .short)
        case "count":
            text = String(entry.journal.entries.count)
        case "example":
            let first = entry.journal.entries.first
            text = first.map { "\(($0.from as NSString).lastPathComponent) → \(($0.to as NSString).lastPathComponent)" } ?? ""
        default:
            text = L10n.t(entry.isReversed ? "renameLog.state.reversed"
                          : entry.reverses != nil ? "renameLog.state.undo" : "renameLog.state.done")
        }
        return ToolUI.cell(in: tableView, text: text)
    }
}
