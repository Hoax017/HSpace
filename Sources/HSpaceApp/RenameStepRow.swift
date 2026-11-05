import AppKit
import BatchRename

/// One step of the pipeline: a kind menu, the fields of that kind, and a remove button.
/// `step` is rebuilt from the controls whenever it is read; `init(step:)` is the way back, used by presets.
@MainActor
final class RenameStepRow: NSView, NSTextFieldDelegate {
    private enum Kind: Int, CaseIterable {
        case replace, changeCase, insert, sequence, date

        var titleKey: String {
            switch self {
            case .replace: "rename.step.replace"
            case .changeCase: "rename.step.case"
            case .insert: "rename.step.insert"
            case .sequence: "rename.step.sequence"
            case .date: "rename.step.date"
            }
        }
    }

    private static let scopes = RenameScope.allCases
    private static let positions = RenamePosition.allCases
    private static let cases = NameCase.allCases
    private static let dateSources = DateSource.allCases

    var onChange: (() -> Void)?
    var onRemove: ((RenameStepRow) -> Void)?

    private let stack = NSStackView()
    private lazy var kindPopup = ToolUI.popup(Kind.allCases.map { L10n.t($0.titleKey) }, label: L10n.t("rename.step.kind"),
                                              target: self, action: #selector(kindChanged))

    // Controls of each kind stay alive while another kind shows, so switching back keeps what was typed
    private lazy var find = ToolUI.field(placeholder: L10n.t("rename.find"), delegate: self)
    private lazy var replacement = ToolUI.field(placeholder: L10n.t("rename.with"), delegate: self)
    private lazy var regex = ToolUI.check(L10n.t("rename.regex"), target: self, action: #selector(changed))
    private lazy var matchCase = ToolUI.check(L10n.t("rename.matchCase"), target: self, action: #selector(changed))
    private lazy var firstOnly = ToolUI.check(L10n.t("rename.firstOnly"), target: self, action: #selector(changed))
    private lazy var scope = scopePopup()
    private lazy var casePopup = ToolUI.popup(Self.cases.map { L10n.t("rename.case.\($0.rawValue)") }, label: L10n.t("rename.step.case"),
                                              target: self, action: #selector(changed))
    private lazy var caseScope = scopePopup()
    private lazy var insertText = ToolUI.field(placeholder: L10n.t("rename.text"), delegate: self)
    private lazy var insertPosition = positionPopup()
    private lazy var start = ToolUI.field("1", placeholder: L10n.t("rename.start"), delegate: self)
    private lazy var increment = ToolUI.field("1", placeholder: L10n.t("rename.increment"), delegate: self)
    private lazy var width = ToolUI.field("1", placeholder: L10n.t("rename.digits"), delegate: self)
    private lazy var sequencePosition = positionPopup()
    private lazy var sequenceSeparator = ToolUI.field(" ", placeholder: L10n.t("rename.separator"), delegate: self)
    private lazy var perFolder = ToolUI.check(L10n.t("rename.perFolder"), target: self, action: #selector(changed))
    private lazy var dateSource = ToolUI.popup(Self.dateSources.map { L10n.t("rename.date.\($0.rawValue)") }, label: L10n.t("rename.step.date"),
                                               target: self, action: #selector(changed))
    private lazy var dateFormat = ToolUI.field("yyyy-MM-dd", placeholder: L10n.t("rename.dateFormat"), delegate: self)
    private lazy var datePosition = positionPopup()
    private lazy var dateSeparator = ToolUI.field(" ", placeholder: L10n.t("rename.separator"), delegate: self)

    init(step: RenameStep) {
        super.init(frame: .zero)
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        for narrow in [start, increment, width, sequenceSeparator, dateSeparator] {
            narrow.widthAnchor.constraint(equalToConstant: 44).isActive = true
        }
        for text in [find, replacement, insertText, dateFormat] {
            text.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        }
        load(step)
        showFields()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    private func scopePopup() -> NSPopUpButton {
        ToolUI.popup(Self.scopes.map { L10n.t("rename.scope.\($0.rawValue)") }, label: L10n.t("rename.scope"),
                     target: self, action: #selector(changed))
    }

    private func positionPopup() -> NSPopUpButton {
        ToolUI.popup(Self.positions.map { L10n.t("rename.position.\($0.rawValue)") }, label: L10n.t("rename.position"),
                     target: self, action: #selector(changed))
    }

    private var kind: Kind { Kind(rawValue: kindPopup.indexOfSelectedItem) ?? .replace }

    private func showFields() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let remove = NSButton(image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: L10n.t("rename.removeStep"))!,
                              target: self, action: #selector(removeTapped))
        remove.isBordered = false
        remove.toolTip = L10n.t("rename.removeStep")
        let fields: [NSView]
        switch kind {
        case .replace: fields = [find, replacement, scope, regex, matchCase, firstOnly]
        case .changeCase: fields = [casePopup, caseScope]
        case .insert: fields = [insertText, insertPosition]
        case .sequence: fields = [start, increment, width, sequenceSeparator, sequencePosition, perFolder]
        case .date: fields = [dateSource, dateFormat, dateSeparator, datePosition]
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        ([kindPopup] + fields + [spacer, remove]).forEach { stack.addArrangedSubview($0) }
    }

    private func number(_ field: NSTextField, fallback: Int) -> Int { Int(field.stringValue) ?? fallback }

    var step: RenameStep {
        switch kind {
        case .replace:
            return .replace(ReplaceStep(find: find.stringValue, replacement: replacement.stringValue,
                                        isRegex: regex.state == .on, caseSensitive: matchCase.state == .on,
                                        firstMatchOnly: firstOnly.state == .on,
                                        scope: Self.scopes[scope.indexOfSelectedItem]))
        case .changeCase:
            return .changeCase(Self.cases[casePopup.indexOfSelectedItem], scope: Self.scopes[caseScope.indexOfSelectedItem])
        case .insert:
            return .insert(text: insertText.stringValue, position: Self.positions[insertPosition.indexOfSelectedItem])
        case .sequence:
            return .sequence(SequenceStep(start: number(start, fallback: 1), increment: number(increment, fallback: 1),
                                          width: min(max(number(width, fallback: 1), 1), 12),
                                          position: Self.positions[sequencePosition.indexOfSelectedItem],
                                          separator: sequenceSeparator.stringValue, restartPerFolder: perFolder.state == .on))
        case .date:
            return .date(DateStep(source: Self.dateSources[dateSource.indexOfSelectedItem], format: dateFormat.stringValue,
                                  position: Self.positions[datePosition.indexOfSelectedItem],
                                  separator: dateSeparator.stringValue))
        }
    }

    private func load(_ step: RenameStep) {
        switch step {
        case .replace(let value):
            kindPopup.selectItem(at: Kind.replace.rawValue)
            find.stringValue = value.find
            replacement.stringValue = value.replacement
            regex.state = value.isRegex ? .on : .off
            matchCase.state = value.caseSensitive ? .on : .off
            firstOnly.state = value.firstMatchOnly ? .on : .off
            scope.selectItem(at: Self.scopes.firstIndex(of: value.scope) ?? 0)
        case .changeCase(let nameCase, let nameScope):
            kindPopup.selectItem(at: Kind.changeCase.rawValue)
            casePopup.selectItem(at: Self.cases.firstIndex(of: nameCase) ?? 0)
            caseScope.selectItem(at: Self.scopes.firstIndex(of: nameScope) ?? 0)
        case .insert(let text, let position):
            kindPopup.selectItem(at: Kind.insert.rawValue)
            insertText.stringValue = text
            insertPosition.selectItem(at: Self.positions.firstIndex(of: position) ?? 0)
        case .sequence(let value):
            kindPopup.selectItem(at: Kind.sequence.rawValue)
            start.stringValue = String(value.start)
            increment.stringValue = String(value.increment)
            width.stringValue = String(value.width)
            sequencePosition.selectItem(at: Self.positions.firstIndex(of: value.position) ?? 0)
            sequenceSeparator.stringValue = value.separator
            perFolder.state = value.restartPerFolder ? .on : .off
        case .date(let value):
            kindPopup.selectItem(at: Kind.date.rawValue)
            dateSource.selectItem(at: Self.dateSources.firstIndex(of: value.source) ?? 0)
            dateFormat.stringValue = value.format
            datePosition.selectItem(at: Self.positions.firstIndex(of: value.position) ?? 0)
            dateSeparator.stringValue = value.separator
        }
    }

    @objc private func kindChanged() {
        showFields()
        changed()
    }

    @objc private func changed() { onChange?() }
    @objc private func removeTapped() { onRemove?(self) }

    func controlTextDidChange(_ notification: Notification) { changed() }
}
