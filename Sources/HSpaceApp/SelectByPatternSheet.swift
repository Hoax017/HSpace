import AppKit
import BatchRename
import HSpaceContracts

/// State of the "select by pattern" sheet, free of AppKit: what the current folder holds, what is selected, and the rule.
@MainActor
final class SelectByPatternModel {
    enum Mode: Int, CaseIterable { case replace, add, remove }
    enum Kinds: Int, CaseIterable { case all, files, folders }

    let items: [FileItem]
    let selected: Set<URL>
    var text = ""
    var kind = NamePatternKind.glob
    var caseSensitive = false
    var invert = false
    var mode = Mode.replace
    var kinds = Kinds.all

    init(items: [FileItem], selected: Set<URL>) {
        self.items = items
        self.selected = selected
    }

    private var pattern: Result<NamePattern, any Error> {
        Result { try NamePattern(text, kind: kind, caseSensitive: caseSensitive) }
    }

    /// Why the pattern cannot be used
    var problem: String? {
        if case .failure(let error) = pattern { return error.localizedDescription }
        return nil
    }

    private func isEligible(_ item: FileItem) -> Bool {
        switch kinds {
        case .all: return true
        case .files: return !item.isDirectory || item.isPackage
        case .folders: return item.isDirectory && !item.isPackage
        }
    }

    /// Items the rule picks, in list order. An empty pattern picks nothing, inverted or not.
    var matches: [URL] {
        guard case .success(let pattern) = pattern, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return items.filter { isEligible($0) && pattern.matches($0.name) != invert }.map(\.url)
    }

    /// The selection to apply
    var result: [URL] {
        let matched = Set(matches)
        switch mode {
        case .replace: return items.map(\.url).filter(matched.contains)
        case .add: return items.map(\.url).filter { matched.contains($0) || selected.contains($0) }
        case .remove: return items.map(\.url).filter { selected.contains($0) && !matched.contains($0) }
        }
    }

    var summary: String {
        problem ?? L10n.f("pattern.summary", matches.count, items.count)
    }
}

/// Select by pattern: a rule, a live count, and the selection changes only on Select.
@MainActor
final class SelectByPatternSheetController: NSObject, NSTextFieldDelegate {
    private static var live: SelectByPatternSheetController?

    let model: SelectByPatternModel
    private let host: NSWindow
    private let apply: ([URL]) -> Void
    private let panel = ToolUI.panel(width: 420, height: 220)
    private lazy var field = ToolUI.field(placeholder: L10n.t("pattern.placeholder"), delegate: self)
    private lazy var kindPopup = ToolUI.popup(NamePatternKind.allCases.map { L10n.t("pattern.kind.\($0.rawValue)") },
                                              label: L10n.t("pattern.kind"), target: self, action: #selector(changed))
    private lazy var itemsPopup = ToolUI.popup(["pattern.items.all", "pattern.items.files", "pattern.items.folders"].map { L10n.t($0) },
                                               label: L10n.t("pattern.items"), target: self, action: #selector(changed))
    private lazy var modePopup = ToolUI.popup(["pattern.mode.replace", "pattern.mode.add", "pattern.mode.remove"].map { L10n.t($0) },
                                              label: L10n.t("pattern.mode"), target: self, action: #selector(changed))
    private lazy var matchCase = ToolUI.check(L10n.t("rename.matchCase"), target: self, action: #selector(changed))
    private lazy var invert = ToolUI.check(L10n.t("pattern.invert"), target: self, action: #selector(changed))
    private lazy var selectButton = ToolUI.button(L10n.t("pattern.select"), target: self, action: #selector(selectTapped))
    private let summary = ToolUI.label()

    static func present(items: [FileItem], selected: [FileItem], in host: NSWindow, apply: @escaping ([URL]) -> Void) {
        guard live == nil, host.attachedSheet == nil else { return }
        let sheet = SelectByPatternSheetController(items: items, selected: Set(selected.map(\.url)), host: host, apply: apply)
        live = sheet
        host.beginSheet(sheet.panel) { _ in }
        sheet.panel.makeFirstResponder(sheet.field)
    }

    init(items: [FileItem], selected: Set<URL>, host: NSWindow, apply: @escaping ([URL]) -> Void) {
        model = SelectByPatternModel(items: items, selected: selected)
        self.host = host
        self.apply = apply
        super.init()
        let cancel = ToolUI.button(L10n.t("common.cancel"), target: self, action: #selector(cancelTapped))
        cancel.keyEquivalent = "\u{1b}"
        selectButton.keyEquivalent = "\r"
        func row(_ views: [NSView]) -> NSStackView {
            let stack = NSStackView(views: views)
            stack.orientation = .horizontal
            stack.spacing = 8
            return stack
        }
        ToolUI.fill(panel, with: [
            ToolUI.title(L10n.t("pattern.title")),
            field,
            row([kindPopup, itemsPopup, modePopup]),
            row([matchCase, invert]),
            ToolUI.buttonRow(leading: summary, [cancel, selectButton]),
        ])
        refresh()
    }

    private func refresh() {
        summary.stringValue = model.summary
        summary.textColor = model.problem == nil ? .secondaryLabelColor : .systemRed
        selectButton.isEnabled = model.problem == nil
    }

    @objc private func changed() {
        model.text = field.stringValue
        model.kind = NamePatternKind.allCases[kindPopup.indexOfSelectedItem]
        model.kinds = SelectByPatternModel.Kinds(rawValue: itemsPopup.indexOfSelectedItem) ?? .all
        model.mode = SelectByPatternModel.Mode(rawValue: modePopup.indexOfSelectedItem) ?? .replace
        model.caseSensitive = matchCase.state == .on
        model.invert = invert.state == .on
        refresh()
    }

    func controlTextDidChange(_ notification: Notification) { changed() }

    @objc private func cancelTapped() { close() }

    @objc private func selectTapped() {
        let urls = model.result
        close()
        apply(urls)
    }

    private func close() {
        host.endSheet(panel)
        panel.orderOut(nil)
        Self.live = nil
    }
}
