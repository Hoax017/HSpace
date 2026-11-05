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
    private let presetMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    private let store: RenameStore?
    private var work: Task<Void, Never>?

    static func present(items: [FileItem], steps: [RenameStep] = [.replace(ReplaceStep(find: "", replacement: ""))],
                        ops: BatchRenameOps, store: RenameStore?, in host: NSWindow) {
        guard live == nil, host.attachedSheet == nil else { return }
        let sheet = BatchRenameSheetController(items: items.map(RenameItem.init), steps: steps,
                                               ops: ops, store: store, host: host)
        live = sheet
        host.beginSheet(sheet.panel) { _ in }
        Task {
            await sheet.reloadPresets()
            await sheet.model.refresh()
        }
    }

    init(items: [RenameItem], steps: [RenameStep], ops: BatchRenameOps, store: RenameStore?, host: NSWindow) {
        model = BatchRenameModel(items: items, steps: steps)
        self.ops = ops
        self.store = store
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

        presetMenu.controlSize = .small
        presetMenu.font = .systemFont(ofSize: 11)
        presetMenu.setAccessibilityLabel(L10n.t("rename.presets"))
        presetMenu.addItem(withTitle: L10n.t("rename.presets"))
        ToolUI.fill(panel, with: [
            ToolUI.buttonRow(leading: ToolUI.title(L10n.f("rename.title", model.items.count)), [presetMenu]),
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

    // MARK: Presets

    /// The pull-down keeps its title in item 0
    private func reloadPresets() async {
        let presets = await store?.presets() ?? []
        ProblemAlert.show(await store?.takeProblem())
        while presetMenu.numberOfItems > 1 { presetMenu.removeItem(at: 1) }
        guard let menu = presetMenu.menu else { return }
        for preset in presets {
            let item = menu.addItem(withTitle: preset.name, action: #selector(presetChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset
        }
        if !presets.isEmpty { menu.addItem(.separator()) }
        let save = menu.addItem(withTitle: L10n.t("rename.savePreset"), action: #selector(savePresetTapped), keyEquivalent: "")
        save.target = self
        guard !presets.isEmpty else { return }
        let delete = menu.addItem(withTitle: L10n.t("rename.deletePreset"), action: nil, keyEquivalent: "")
        let deletions = NSMenu()
        for preset in presets {
            let item = deletions.addItem(withTitle: preset.name, action: #selector(deleteChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset
        }
        delete.submenu = deletions
    }

    func load(_ preset: RenamePreset) {
        rows.forEach { $0.removeFromSuperview() }
        rows = []
        preset.steps.forEach { append(RenameStepRow(step: $0)) }
        addButton.isEnabled = rows.count < Self.maxSteps
        stepsChanged()
    }

    var currentSteps: [RenameStep] { rows.map(\.step) }

    @objc private func presetChosen(_ sender: NSMenuItem) {
        guard let preset = sender.representedObject as? RenamePreset else { return }
        load(preset)
    }

    @objc private func deleteChosen(_ sender: NSMenuItem) {
        guard let preset = sender.representedObject as? RenamePreset, let store else { return }
        Task {
            do { try await store.deletePreset(id: preset.id) } catch { ToolUI.showError(error.localizedDescription, in: panel) }
            await reloadPresets()
        }
    }

    @objc private func savePresetTapped() {
        guard let store else { return }
        let alert = NSAlert()
        alert.messageText = L10n.t("rename.savePreset")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = L10n.t("rename.presetName")
        field.setAccessibilityLabel(L10n.t("rename.presetName"))
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.t("rename.savePreset.confirm"))
        alert.addButton(withTitle: L10n.t("common.cancel"))
        alert.window.initialFirstResponder = field
        let steps = currentSteps
        alert.beginSheetModal(for: panel) { [weak self] response in
            MainActor.assumeIsolated {
                let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard response == .alertFirstButtonReturn, !name.isEmpty else { return }
                Task {
                    do { try await store.savePreset(named: name, steps: steps) } catch {
                        ToolUI.showError(error.localizedDescription, in: self?.panel)
                    }
                    await self?.reloadPresets()
                }
            }
        }
    }

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
