import AppKit
import BatchRename
import HSpaceContracts

/// The state of the quick rename sheet: one line of text per selected item.
@MainActor
final class QuickRenameModel {
    let sources: [URL]
    private(set) var plan: RenamePlan?
    private(set) var problem: String?

    init(sources: [URL]) { self.sources = sources }

    var initialText: String { sources.map(\.lastPathComponent).joined(separator: "\n") }
    var canApply: Bool { problem == nil && plan?.canApply == true }

    func update(text: String) {
        do {
            let plan = try BatchRenamePlanner.plan(sources: sources, text: text)
            self.plan = plan
            let blocked = plan.rows.first { if case .blocked = $0.status { true } else { false } }
            problem = blocked.map { "\($0.newName): \(BatchRenameModel.text(for: $0.status))" }
        } catch {
            plan = nil
            problem = error.localizedDescription
        }
    }

    var summary: String {
        if let problem { return problem }
        guard let plan, plan.changeCount > 0 else { return L10n.t("rename.summary.none") }
        return L10n.f("rename.summary.ready", plan.changeCount)
    }
}

/// Quick rename: edit a few names as text, with find and replace, multiple cursors or paste from elsewhere.
/// Same engine as batch rename, so it has the same collision check and one undo.
@MainActor
final class QuickRenameSheetController: NSObject, NSTextViewDelegate {
    /// Above this, the preview of the full batch rename sheet is the better tool
    static let itemLimit = 30
    private static var live: QuickRenameSheetController?

    let model: QuickRenameModel
    private let ops: BatchRenameOps
    private let host: NSWindow
    private let panel = ToolUI.panel(width: 480, height: 320)
    private let text = NSTextView()
    private let summary = ToolUI.label()
    private lazy var renameButton = ToolUI.button(L10n.t("rename.apply"), target: self, action: #selector(renameTapped))
    private var work: Task<Void, Never>?

    static func present(items: [FileItem], ops: BatchRenameOps, in host: NSWindow) {
        guard live == nil, host.attachedSheet == nil else { return }
        let sheet = QuickRenameSheetController(sources: items.map(\.url), ops: ops, host: host)
        live = sheet
        host.beginSheet(sheet.panel) { _ in }
        sheet.panel.makeFirstResponder(sheet.text)
    }

    init(sources: [URL], ops: BatchRenameOps, host: NSWindow) {
        model = QuickRenameModel(sources: sources)
        self.ops = ops
        self.host = host
        super.init()

        text.string = model.initialText
        text.font = .systemFont(ofSize: 12)
        text.textColor = .labelColor
        text.backgroundColor = .textBackgroundColor
        text.isRichText = false
        text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.setAccessibilityLabel(L10n.t("quickRename.names"))
        text.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        let cancel = ToolUI.button(L10n.t("common.cancel"), target: self, action: #selector(cancelTapped))
        cancel.keyEquivalent = "\u{1b}"
        renameButton.keyEquivalent = "\r"
        renameButton.keyEquivalentModifierMask = .command
        renameButton.toolTip = L10n.t("rename.apply.tip")
        ToolUI.fill(panel, with: [
            ToolUI.title(L10n.t("quickRename.title")),
            ToolUI.label(L10n.t("quickRename.hint")),
            scroll,
            ToolUI.buttonRow(leading: summary, [cancel, renameButton]),
        ])
        refresh()
    }

    func textDidChange(_ notification: Notification) { refresh() }

    private func refresh() {
        model.update(text: text.string)
        summary.stringValue = model.summary
        summary.textColor = model.problem == nil ? .secondaryLabelColor : .systemRed
        renameButton.isEnabled = model.canApply && work == nil
    }

    @objc private func cancelTapped() {
        guard work == nil else { return }
        close()
    }

    @objc private func renameTapped() {
        guard model.canApply, work == nil, let plan = model.plan else { return }
        renameButton.isEnabled = false
        work = Task { [weak self] in
            do {
                guard let journal = try await self?.ops.apply(plan, progress: { _, _ in }), let self else { return }
                self.work = nil
                self.close()
                Toast.show(L10n.f("toast.renamedN", journal.entries.count), in: self.host)
            } catch {
                guard let self else { return }
                self.work = nil
                self.refresh()
                ToolUI.showError(error.localizedDescription, in: self.panel)
            }
        }
    }

    private func close() {
        host.endSheet(panel)
        panel.orderOut(nil)
        Self.live = nil
    }
}
