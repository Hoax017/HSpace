import AppKit
import BatchRename
import HSpaceContracts

/// Batch rename: steps on top, a live preview with one status per row below. Rename stays disabled while any row is blocked.
/// ⌘Return renames: a plain Return belongs to the text fields, where a stray press must not start a batch.
@MainActor
final class BatchRenameSheetController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static var live: BatchRenameSheetController?
    private static let maxSteps = 8

    let model: BatchRenameModel
    private let ops: BatchRenameOps
    private let host: NSWindow
    private let panel = ToolUI.panel(width: 800, height: 560)
    private let stepStack = NSStackView()
    private var rows: [RenameStepRow] = []
    private var table: NSTableView!
    private let summary = ToolUI.label()
    private let bar = ToolUI.progressBar()
    private lazy var cancelButton = ToolUI.button(L10n.t("common.cancel"), target: self, action: #selector(cancelTapped))
    private lazy var renameButton = ToolUI.button(L10n.t("rename.apply"), target: self, action: #selector(renameTapped))
    private lazy var addButton = ToolUI.button(L10n.t("rename.addStep"), target: self, action: #selector(addTapped))
    private var work: Task<Void, Never>?

    static func present(items: [FileItem], coordinator: FileOpsCoordinator, in host: NSWindow) {
        guard live == nil, host.attachedSheet == nil else { return }
        let sheet = BatchRenameSheetController(items: items.map(RenameItem.init), steps: [.replace(ReplaceStep(find: "", replacement: ""))],
                                               ops: BatchRenameOps(coordinator: coordinator), host: host)
        live = sheet
        host.beginSheet(sheet.panel) { _ in }
        Task { await sheet.model.refresh() }
    }

    init(items: [RenameItem], steps: [RenameStep], ops: BatchRenameOps, host: NSWindow) {
        model = BatchRenameModel(items: items, steps: steps)
        self.ops = ops
        self.host = host
        super.init()
        build()
        steps.forEach { append(RenameStepRow(step: $0)) }
        model.onChange = { [weak self] in self?.modelChanged() }
    }

    private func build() {
        stepStack.orientation = .vertical
        stepStack.alignment = .leading
        stepStack.spacing = 4

        let (scroll, table) = ToolUI.table(columns: [
            ("old", L10n.t("rename.column.old"), 280),
            ("new", L10n.t("rename.column.new"), 280),
            ("status", L10n.t("rename.column.status"), 140),
        ], source: self, height: 240)
        self.table = table

        cancelButton.keyEquivalent = "\u{1b}"
        renameButton.keyEquivalent = "\r"
        renameButton.keyEquivalentModifierMask = .command
        renameButton.toolTip = L10n.t("rename.apply.tip")
        renameButton.isEnabled = false

        ToolUI.fill(panel, with: [
            ToolUI.title(L10n.f("rename.title", model.items.count)),
            stepStack,
            addButton,
            scroll,
            bar,
            ToolUI.buttonRow(leading: summary, [cancelButton, renameButton]),
        ])
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
    }

    private func append(_ row: RenameStepRow) {
        row.onChange = { [weak self] in self?.stepsChanged() }
        row.onRemove = { [weak self] in self?.remove($0) }
        rows.append(row)
        stepStack.addArrangedSubview(row)
        row.leadingAnchor.constraint(equalTo: stepStack.leadingAnchor).isActive = true
        row.trailingAnchor.constraint(equalTo: stepStack.trailingAnchor).isActive = true
        addButton.isEnabled = rows.count < Self.maxSteps
    }

    private func remove(_ row: RenameStepRow) {
        rows.removeAll { $0 === row }
        row.removeFromSuperview()
        addButton.isEnabled = true
        stepsChanged()
    }

    private func stepsChanged() { model.setSteps(rows.map(\.step)) }

    private func modelChanged() {
        table.reloadData()
        summary.stringValue = model.summary
        summary.textColor = model.stepError != nil || (model.plan?.blockedCount ?? 0) > 0 ? .systemRed : .secondaryLabelColor
        renameButton.isEnabled = model.canApply && work == nil
    }

    // MARK: Actions

    @objc private func addTapped() {
        append(RenameStepRow(step: .sequence(SequenceStep())))
        stepsChanged()
    }

    @objc private func cancelTapped() {
        if let work {
            work.cancel()   // The engine reverses what landed; the sheet stays until it has
        } else {
            close()
        }
    }

    @objc private func renameTapped() {
        guard model.canApply, work == nil, let plan = model.plan else { return }
        setRunning(true)
        let bar = bar
        work = Task { [weak self] in
            do {
                let journal = try await self?.ops.apply(plan) { done, total in
                    Task { @MainActor in bar.doubleValue = Double(done) / Double(max(total, 1)) }
                }
                guard let self else { return }
                let window = self.host
                self.work = nil
                self.close()
                Toast.show(L10n.f("toast.renamedN", journal?.entries.count ?? 0), in: window)
            } catch is CancellationError {
                self?.finishFailed(nil)
            } catch {
                self?.finishFailed(error.localizedDescription)
            }
        }
    }

    private func finishFailed(_ message: String?) {
        work = nil
        setRunning(false)
        Task { await model.refresh() }
        if let message { ToolUI.showError(message, in: panel) }
    }

    private func setRunning(_ running: Bool) {
        bar.isHidden = !running
        bar.doubleValue = 0
        renameButton.isEnabled = !running && model.canApply
        addButton.isEnabled = !running && rows.count < Self.maxSteps
        rows.forEach { $0.isHidden = running }
    }

    private func close() {
        host.endSheet(panel)
        panel.orderOut(nil)
        Self.live = nil
    }

    // MARK: Preview table

    func numberOfRows(in tableView: NSTableView) -> Int { model.plan?.rows.count ?? model.items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = tableColumn?.identifier.rawValue
        guard let planned = model.plan?.rows[safe: row] else {
            return id == "old" ? ToolUI.cell(in: tableView, text: model.items[row].url.lastPathComponent) : nil
        }
        switch id {
        case "old":
            return ToolUI.cell(in: tableView, text: planned.source.lastPathComponent)
        case "new":
            return ToolUI.cell(in: tableView, text: planned.newName, color: planned.status == .unchanged ? .secondaryLabelColor : .labelColor)
        default:
            var color = NSColor.secondaryLabelColor
            if case .blocked = planned.status { color = .systemRed }
            return ToolUI.cell(in: tableView, text: BatchRenameModel.text(for: planned.status), color: color)
        }
    }
}

extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
