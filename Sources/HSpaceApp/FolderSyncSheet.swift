import AppKit
import FolderSync
import HSpaceContracts

extension FileOpsCoordinator {
    /// Submits and waits, for work that must stop on the first failure. Cancelling the calling task cancels the operation.
    private func runChecked(_ spec: OperationSpec) async throws -> OperationReceipt? {
        let ticket = historyTicket(for: spec)
        let id = await kernel.submit(spec)
        let kernel = self.kernel
        await withTaskCancellationHandler {
            for await projection in await kernel.projections() where projection.id == id && projection.state.isTerminal { break }
        } onCancel: {
            Task { await kernel.cancel(id) }
        }
        await recordHistory(ticket, id: id)
        switch await kernel.projection(id)?.state {
        case .cancelled: throw CancellationError()
        case .failed(let message, _): throw SyncOperationError(message: message)
        default: return await kernel.receipt(id)
        }
    }

    /// Keeps Put Back working for what a sync sent to the Trash
    private func trashForSync(_ items: [URL]) async throws {
        let receipt = try await runChecked(OperationSpec(kind: .trash, sources: items))
        await trashLedger?.record(receipt?.trashedItems.map { (original: $0.original, trashed: $0.trashed) } ?? [])
        ProblemAlert.show(await trashLedger?.takeProblem())
    }

    /// The sync's way to the disk: ordinary kernel operations, with progress in the task list and a line in the history.
    func syncDriver() -> SyncDriver {
        SyncDriver(
            copy: { [weak self] sources, folder in
                _ = try await self?.runChecked(OperationSpec(kind: .copy, sources: sources, destination: folder))
            },
            trash: { [weak self] items in
                try await self?.trashForSync(items)
            },
            makeFolder: { [weak self] name, parent in
                _ = try await self?.runChecked(OperationSpec(kind: .newFolder, sources: [], destination: parent, newName: name))
            })
    }
}

struct SyncOperationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Texts and decisions of the sync sheet, apart from its controls.
@MainActor
enum FolderSyncModel {
    /// "*.jpg; *.png" → the globs, without blanks
    static func patterns(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == ";" || $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func actionName(_ action: SyncAction) -> String {
        switch action.kind {
        case .createFolder: L10n.t("sync.action.createFolder")
        case .copy: L10n.t("sync.action.copy")
        case .replace: L10n.t("sync.action.replace")
        case .delete: L10n.t("sync.action.delete")
        case .skip: L10n.t("sync.action.skip")
        }
    }

    static func note(_ action: SyncAction) -> String {
        switch action.kind {
        case .skip(.typeMismatch): L10n.t("sync.note.typeMismatch")
        case .skip(.undecided): L10n.t("sync.note.undecided")
        case .skip(.scanIncomplete): L10n.t("sync.note.scanIncomplete")
        default: action.targetIsNewer ? L10n.t("sync.note.targetNewer") : ""
        }
    }

    static func summary(_ plan: SyncPlan) -> String {
        guard plan.hasWork || !plan.skipped.isEmpty else { return L10n.f("sync.summary.none", plan.identicalCount) }
        var text = L10n.f("sync.summary", plan.count(.copy), plan.count(.replace), plan.deletes.count, plan.skipped.count,
                          Formatters.size.string(fromByteCount: plan.bytesToCopy))
        if plan.extrasKept > 0 { text += " " + L10n.f("sync.summary.extrasKept", plan.extrasKept) }
        if let first = plan.problems.first { text += " " + L10n.f("sync.summary.problems", plan.problems.count, first.path) }
        return text
    }

    static func summary(_ report: SyncReport) -> String {
        var parts: [String] = [L10n.f(report.isDryRun ? "sync.report.dryRun" : "sync.report",
                                      report.copied, report.replaced, report.deleted)]
        if !report.changedSincePreview.isEmpty {
            parts.append(L10n.f("sync.report.changed", report.changedSincePreview.count, report.changedSincePreview[0]))
        }
        if let failure = report.failures.first { parts.append(L10n.f("sync.report.failed", failure.path, failure.message)) }
        if report.wasCancelled { parts.append(L10n.t("sync.report.cancelled")) }
        return parts.joined(separator: " ")
    }

    /// Text of the delete confirmation: how many, which, and a warning when it looks like the wrong folder
    static func deleteQuestion(_ plan: SyncPlan) -> (title: String, body: String) {
        let names = plan.deletes.prefix(5).map(\.relativePath).joined(separator: "\n")
        var body = names
        if plan.deletes.count > 5 { body += "\n" + L10n.f("sync.delete.more", plan.deletes.count - 5) }
        if plan.wouldEmptyReceiver { body = L10n.t("sync.delete.emptyWarning") + "\n\n" + body }
        return (L10n.f("sync.delete.title", plan.deletes.count), body + "\n\n" + L10n.t("sync.delete.body"))
    }
}

/// Compare two folders, look at the plan, then sync. Nothing changes on disk before Sync, and with Dry Run on, not even then.
@MainActor
final class FolderSyncSheetController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private static var live: FolderSyncSheetController?

    private let coordinator: FileOpsCoordinator
    private let store: SyncPresetStore
    private let host: NSWindow
    private let panel = ToolUI.panel(width: 720, height: 600)
    private var table: NSTableView!
    private var plan: SyncPlan?
    private var saved: [SyncPreset] = []
    private var work: Task<Void, Never>?

    private lazy var leftField = ToolUI.field(placeholder: L10n.t("sync.left"), delegate: self)
    private lazy var rightField = ToolUI.field(placeholder: L10n.t("sync.right"), delegate: self)
    private lazy var includeField = ToolUI.field(placeholder: L10n.t("sync.include"), delegate: self)
    private lazy var excludeField = ToolUI.field(SyncFilter().exclude.joined(separator: "; "), placeholder: L10n.t("sync.exclude"), delegate: self)
    private lazy var presetPopup = ToolUI.popup([], label: L10n.t("sync.preset"), target: self, action: #selector(presetChosen(_:)))
    private lazy var directionPopup = ToolUI.popup(SyncDirection.allCases.map { L10n.t("sync.direction.\($0.rawValue)") },
                                                   label: L10n.t("sync.direction"), target: self, action: #selector(optionsChanged(_:)))
    private lazy var comparisonPopup = ToolUI.popup(SyncComparison.allCases.map { L10n.t("sync.comparison.\($0.rawValue)") },
                                                    label: L10n.t("sync.comparison"), target: self, action: #selector(optionsChanged(_:)))
    private lazy var hiddenCheck = ToolUI.check(L10n.t("sync.skipHidden"), target: self, action: #selector(optionsChanged(_:)))
    private lazy var deleteCheck = ToolUI.check(L10n.t("sync.deleteExtras"), target: self, action: #selector(optionsChanged(_:)))
    private lazy var dryRunCheck = ToolUI.check(L10n.t("sync.dryRun"), target: self, action: #selector(dryRunChanged(_:)))
    private lazy var compareButton = ToolUI.button(L10n.t("sync.compare"), target: self, action: #selector(compareTapped))
    private lazy var syncButton = ToolUI.button(L10n.t("sync.run"), target: self, action: #selector(syncTapped))
    private lazy var closeButton = ToolUI.button(L10n.t("common.close"), target: self, action: #selector(closeTapped))
    private lazy var savePresetButton = ToolUI.button(L10n.t("sync.savePreset"), target: self, action: #selector(savePresetTapped))
    private lazy var deletePresetButton = ToolUI.button(L10n.t("sync.deletePreset"), target: self, action: #selector(deletePresetTapped))
    private let summary = ToolUI.label()
    private let bar = ToolUI.progressBar()

    static func present(coordinator: FileOpsCoordinator, store: SyncPresetStore, left: URL?, right: URL?, in host: NSWindow) {
        guard live == nil, host.attachedSheet == nil else { return }
        let sheet = FolderSyncSheetController(coordinator: coordinator, store: store, host: host)
        sheet.leftField.stringValue = left?.path ?? ""
        sheet.rightField.stringValue = right?.path ?? ""
        live = sheet
        host.beginSheet(sheet.panel) { _ in }
        Task { await sheet.reloadPresets() }
    }

    init(coordinator: FileOpsCoordinator, store: SyncPresetStore, host: NSWindow) {
        self.coordinator = coordinator
        self.store = store
        self.host = host
        super.init()
        let (scroll, table) = ToolUI.table(columns: [
            ("action", L10n.t("sync.column.action"), 80),
            ("side", L10n.t("sync.column.side"), 40),
            ("path", L10n.t("sync.column.path"), 340),
            ("size", L10n.t("sync.column.size"), 72),
            ("note", L10n.t("sync.column.note"), 120),
        ], source: self, height: 240)
        self.table = table
        dryRunCheck.state = .on
        summary.lineBreakMode = .byWordWrapping
        summary.maximumNumberOfLines = 3
        closeButton.keyEquivalent = "\u{1b}"
        compareButton.keyEquivalent = "\r"
        syncButton.isEnabled = false
        ToolUI.fill(panel, with: [
            ToolUI.title(L10n.t("sync.title")),
            folderRow(leftField, #selector(chooseLeft)),
            folderRow(rightField, #selector(chooseRight)),
            controlRow([presetPopup, savePresetButton, deletePresetButton]),
            controlRow([directionPopup, comparisonPopup, hiddenCheck, deleteCheck]),
            controlRow([includeField, excludeField]),
            scroll, bar, summary,
            ToolUI.buttonRow(leading: dryRunCheck, [closeButton, compareButton, syncButton]),
        ])
        updateControls()
    }

    private func folderRow(_ field: NSTextField, _ action: Selector) -> NSStackView {
        controlRow([field, ToolUI.button(L10n.t("sync.choose"), target: self, action: action)])
    }

    private func controlRow(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    // MARK: Presets

    private var allPresets: [SyncPreset] { SyncPresetStore.builtIn + saved }

    private func reloadPresets() async {
        saved = await store.saved()
        ProblemAlert.show(await store.takeProblem())
        let selected = presetPopup.indexOfSelectedItem
        presetPopup.removeAllItems()
        presetPopup.addItems(withTitles: SyncPresetStore.builtIn.map { L10n.t("sync.preset.\($0.name)") } + saved.map(\.name))
        if presetPopup.numberOfItems > max(selected, 0) { presetPopup.selectItem(at: max(selected, 0)) }
        updateControls()
    }

    @objc private func presetChosen(_ sender: Any?) {
        guard allPresets.indices.contains(presetPopup.indexOfSelectedItem) else { return }
        apply(allPresets[presetPopup.indexOfSelectedItem])
    }

    private func apply(_ preset: SyncPreset) {
        directionPopup.selectItem(at: SyncDirection.allCases.firstIndex(of: preset.options.direction) ?? 0)
        comparisonPopup.selectItem(at: SyncComparison.allCases.firstIndex(of: preset.options.comparison) ?? 0)
        deleteCheck.state = preset.options.deleteExtras ? .on : .off
        hiddenCheck.state = preset.options.filter.skipHidden ? .on : .off
        includeField.stringValue = preset.options.filter.include.joined(separator: "; ")
        excludeField.stringValue = preset.options.filter.exclude.joined(separator: "; ")
        if let left = preset.left { leftField.stringValue = left }
        if let right = preset.right { rightField.stringValue = right }
        invalidatePlan()
    }

    @objc private func savePresetTapped() {
        let alert = NSAlert()
        alert.messageText = L10n.t("sync.savePreset.title")
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        name.setAccessibilityLabel(L10n.t("sync.savePreset.title"))
        alert.accessoryView = name
        alert.addButton(withTitle: L10n.t("sync.savePreset"))
        alert.addButton(withTitle: L10n.t("common.cancel"))
        alert.beginSheetModal(for: panel) { [self] response in
            let text = name.stringValue.trimmingCharacters(in: .whitespaces)
            guard response == .alertFirstButtonReturn, !text.isEmpty else { return }
            let preset = SyncPreset(name: text, options: options, left: leftField.stringValue, right: rightField.stringValue)
            Task {
                await store.save(preset)
                await reloadPresets()
                presetPopup.selectItem(withTitle: text)
                updateControls()
            }
        }
    }

    @objc private func deletePresetTapped() {
        let index = presetPopup.indexOfSelectedItem - SyncPresetStore.builtIn.count
        guard saved.indices.contains(index) else { return }
        let id = saved[index].id
        presetPopup.selectItem(at: 0)
        Task {
            await store.remove(id)
            await reloadPresets()
        }
    }

    // MARK: Options

    private var options: SyncOptions {
        SyncOptions(direction: SyncDirection.allCases[max(directionPopup.indexOfSelectedItem, 0)],
                    comparison: SyncComparison.allCases[max(comparisonPopup.indexOfSelectedItem, 0)],
                    deleteExtras: deleteCheck.state == .on,
                    filter: SyncFilter(include: FolderSyncModel.patterns(includeField.stringValue),
                                       exclude: FolderSyncModel.patterns(excludeField.stringValue),
                                       skipHidden: hiddenCheck.state == .on))
    }

    func controlTextDidChange(_ obj: Notification) { invalidatePlan() }

    @objc private func optionsChanged(_ sender: Any?) { invalidatePlan() }

    @objc private func dryRunChanged(_ sender: Any?) { updateControls() }

    /// A plan answers one exact question: any change to the question throws it away.
    private func invalidatePlan() {
        plan = nil
        table.reloadData()
        summary.stringValue = ""
        updateControls()
    }

    private func updateControls() {
        let busy = work != nil
        compareButton.isEnabled = !busy
        syncButton.isEnabled = !busy && plan?.hasWork == true
        syncButton.title = L10n.t(dryRunCheck.state == .on ? "sync.runDry" : "sync.run")
        closeButton.title = L10n.t(busy ? "common.cancel" : "common.close")
        deleteCheck.isEnabled = options.direction != .twoWay
        deletePresetButton.isEnabled = presetPopup.indexOfSelectedItem >= SyncPresetStore.builtIn.count
        bar.isHidden = !busy
    }

    @objc private func chooseLeft() { choose(into: leftField) }
    @objc private func chooseRight() { choose(into: rightField) }

    private func choose(into field: NSTextField) {
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        if !field.stringValue.isEmpty { open.directoryURL = URL(fileURLWithPath: field.stringValue) }
        open.beginSheetModal(for: panel) { [self] response in
            guard response == .OK, let url = open.url else { return }
            field.stringValue = url.path
            invalidatePlan()
        }
    }

    // MARK: Compare

    @objc private func compareTapped() {
        let left = URL(fileURLWithPath: leftField.stringValue), right = URL(fileURLWithPath: rightField.stringValue)
        guard !leftField.stringValue.isEmpty, !rightField.stringValue.isEmpty else {
            summary.stringValue = L10n.t("sync.needFolders")
            return
        }
        guard !FileOpsCoordinator.isTrashDestination(left), !FileOpsCoordinator.isTrashDestination(right) else {
            summary.stringValue = L10n.t("sync.noTrash")
            return
        }
        let options = options
        invalidatePlan()
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        summary.stringValue = L10n.t("sync.comparing")
        work = Task { [self] in
            let task = Task.detached { try SyncPlanner.plan(left: left, right: right, options: options) }
            do {
                let plan = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                self.plan = plan
                summary.stringValue = FolderSyncModel.summary(plan)
            } catch is CancellationError {
                summary.stringValue = L10n.t("sync.report.cancelled")
            } catch {
                summary.stringValue = error.localizedDescription
            }
            bar.stopAnimation(nil)
            bar.isIndeterminate = false
            work = nil
            table.reloadData()
            updateControls()
        }
        updateControls()
    }

    // MARK: Sync

    @objc private func syncTapped() {
        guard let plan else { return }
        guard dryRunCheck.state == .off else {
            run(plan, mode: .dryRun)
            return
        }
        guard !plan.deletes.isEmpty else {
            run(plan, mode: .apply(confirmedDeletes: false))
            return
        }
        let question = FolderSyncModel.deleteQuestion(plan)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = question.title
        alert.informativeText = question.body
        // Cancel first, as for Empty Trash: Return must not delete anything
        alert.addButton(withTitle: L10n.t("common.cancel"))
        alert.addButton(withTitle: L10n.t("sync.delete.confirm"))
        alert.buttons[1].hasDestructiveAction = true
        alert.beginSheetModal(for: panel) { [self] response in
            guard response == .alertSecondButtonReturn else { return }
            run(plan, mode: .apply(confirmedDeletes: true))
        }
    }

    private func run(_ plan: SyncPlan, mode: SyncMode) {
        let driver = coordinator.syncDriver()
        bar.doubleValue = 0
        let bar = self.bar
        summary.stringValue = L10n.t("sync.running")
        work = Task { [self] in
            let report = await coordinator.historyGroup(L10n.t("history.group.sync")) {
                await SyncExecutor.run(plan, mode: mode, driver: driver) { done, total in
                    Task { @MainActor in bar.doubleValue = Double(done) / Double(max(total, 1)) }
                }
            }
            work = nil
            summary.stringValue = FolderSyncModel.summary(report)
            if mode != .dryRun {
                // The disk moved on: the old plan no longer describes it
                self.plan = nil
                table.reloadData()
                coordinator.reloadLists()
            }
            updateControls()
        }
        updateControls()
    }

    @objc private func closeTapped() {
        if let work {
            work.cancel()
            return
        }
        host.endSheet(panel)
        Self.live = nil
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { plan?.actions.count ?? 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let action = plan?.actions[safe: row], let column = tableColumn?.identifier.rawValue else { return nil }
        let text: String
        switch column {
        case "action": text = FolderSyncModel.actionName(action)
        case "side": text = action.towardRight ? "→" : "←"
        case "path": text = action.relativePath
        case "size": text = action.bytes > 0 ? Formatters.size.string(fromByteCount: action.bytes) : ""
        default: text = FolderSyncModel.note(action)
        }
        return ToolUI.cell(in: tableView, text: text, color: action.kind == .delete ? .systemRed : .labelColor)
    }
}

extension MainWindowController {
    @objc func showFolderSync(_ sender: Any?) {
        guard let window, let store = (NSApp.delegate as? AppDelegate)?.syncPresetStore else { NSSound.beep(); return }
        let panes = grid.visiblePanes
        let left = grid.activePane.activeTab.browser.current
        let right = panes.count > 1 ? panes[(grid.activePaneIndex + 1) % panes.count].activeTab.browser.current : nil
        FolderSyncSheetController.present(coordinator: coordinator, store: store, left: left, right: right, in: window)
    }
}
