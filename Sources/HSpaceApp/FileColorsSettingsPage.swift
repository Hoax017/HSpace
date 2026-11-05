import AppKit
import FileMetadata

/// One rule's condition as the settings row edits it. Pure, so the parsing is tested without a window.
struct RuleConditionForm: Equatable {
    enum Kind: Int, CaseIterable {
        case nameContains, fileExtension, hasTag, isFolder, modifiedWithin

        var titleKey: String { "settings.rule.kind.\(rawValue)" }
        var takesValue: Bool { self != .isFolder }
    }

    var kind: Kind
    var value: String

    init(kind: Kind, value: String) {
        self.kind = kind
        self.value = value
    }

    init(_ condition: RuleCondition) {
        switch condition {
        case .nameContains(let text): self.init(kind: .nameContains, value: text)
        case .fileExtension(let list): self.init(kind: .fileExtension, value: list.joined(separator: ", "))
        case .hasTag(let name): self.init(kind: .hasTag, value: name)
        case .isFolder: self.init(kind: .isFolder, value: "")
        case .modifiedWithin(let days): self.init(kind: .modifiedWithin, value: String(days))
        }
    }

    /// nil while the row is not a usable rule yet, for example an empty name
    var condition: RuleCondition? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .isFolder:
            return .isFolder
        case .nameContains:
            return text.isEmpty ? nil : .nameContains(text)
        case .hasTag:
            return text.isEmpty ? nil : .hasTag(text)
        case .fileExtension:
            let list = text.split(whereSeparator: { $0 == "," || $0 == " " })
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
                .filter { !$0.isEmpty }
            return list.isEmpty ? nil : .fileExtension(list)
        case .modifiedWithin:
            guard let days = Int(text), days > 0 else { return nil }
            return .modifiedWithin(days: days)
        }
    }
}

/// Settings page for colour rules. Changes apply at once, and every control is a native one.
@MainActor
final class FileColorsSettingsPage: NSObject, SettingsPage {
    var pageTitleKey: String { "settings.tab.fileColors" }

    private let rows = NSStackView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    /// What is on screen, including rows not yet valid. Saved when valid; others keep their last good condition.
    private var rules: [ColorRule] = []
    private var drafts: [UUID: RuleConditionForm] = [:]

    func makeView() -> NSView {
        rules = MetadataSettings.colorRules
        let note = NSTextField(wrappingLabelWithString: L10n.t("settings.rule.note"))
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 4
        rebuildRows()

        let add = NSButton(title: L10n.t("settings.rule.add"), target: self, action: #selector(addRule(_:)))
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true

        let stack = NSStackView(views: [note, rows, add, errorLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
        ])
        return container
    }

    private func rebuildRows() {
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, rule) in rules.enumerated() {
            rows.addArrangedSubview(makeRow(rule, index: index))
        }
    }

    private func makeRow(_ rule: ColorRule, index: Int) -> NSView {
        let form = drafts[rule.id] ?? RuleConditionForm(rule.condition)
        let tag = index

        let enabled = NSButton(checkboxWithTitle: "", target: self, action: #selector(enabledChanged(_:)))
        enabled.state = rule.enabled ? .on : .off
        enabled.tag = tag
        enabled.setAccessibilityLabel(L10n.t("settings.rule.enabled"))

        let colorPopup = NSPopUpButton()
        for color in FileColor.allCases {
            colorPopup.addItem(withTitle: FileColorPalette.name(color))
            colorPopup.lastItem?.image = FileColorPalette.menuImage(color)
            colorPopup.lastItem?.representedObject = color.rawValue
        }
        colorPopup.selectItem(at: FileColor.allCases.firstIndex(of: rule.color) ?? 0)
        colorPopup.tag = tag
        colorPopup.target = self
        colorPopup.action = #selector(colorChanged(_:))
        colorPopup.setAccessibilityLabel(L10n.t("settings.rule.color"))

        let kindPopup = NSPopUpButton()
        for kind in RuleConditionForm.Kind.allCases {
            kindPopup.addItem(withTitle: L10n.t(kind.titleKey))
        }
        kindPopup.selectItem(at: form.kind.rawValue)
        kindPopup.tag = tag
        kindPopup.target = self
        kindPopup.action = #selector(kindChanged(_:))
        kindPopup.setAccessibilityLabel(L10n.t("settings.rule.condition"))

        let field = NSTextField(string: form.value)
        field.isHidden = !form.kind.takesValue
        field.tag = tag
        field.target = self
        field.action = #selector(valueChanged(_:))
        field.placeholderString = L10n.t("settings.rule.value")
        field.setAccessibilityLabel(L10n.t("settings.rule.value"))
        field.widthAnchor.constraint(equalToConstant: 148).isActive = true

        let up = iconButton("chevron.up", "settings.rule.up", #selector(moveUp(_:)), tag: tag)
        up.isEnabled = index > 0
        let down = iconButton("chevron.down", "settings.rule.down", #selector(moveDown(_:)), tag: tag)
        down.isEnabled = index < rules.count - 1
        let remove = iconButton("minus.circle", "settings.rule.remove", #selector(removeRule(_:)), tag: tag)

        let line = NSStackView(views: [enabled, colorPopup, kindPopup, field, up, down, remove])
        line.orientation = .horizontal
        line.spacing = 8
        return line
    }

    private func iconButton(_ symbol: String, _ titleKey: String, _ action: Selector, tag: Int) -> NSButton {
        let title = L10n.t(titleKey)
        let button = NSButton(image: NSImage.officialSymbol(symbol, accessibility: title) ?? NSImage(),
                              target: self, action: action)
        button.isBordered = false
        button.toolTip = title
        button.tag = tag
        return button
    }

    private func save() {
        let snapshot = rules
        Task {
            let problem = await MetadataSettings.setColorRules(snapshot)
            errorLabel.stringValue = problem ?? ""
            errorLabel.isHidden = problem == nil
        }
    }

    @objc private func addRule(_ sender: Any?) {
        rules.append(ColorRule(color: .blue, condition: .isFolder))
        rebuildRows()
        save()
    }

    @objc private func removeRule(_ sender: NSButton) {
        guard rules.indices.contains(sender.tag) else { return }
        drafts[rules[sender.tag].id] = nil
        rules.remove(at: sender.tag)
        rebuildRows()
        save()
    }

    @objc private func moveUp(_ sender: NSButton) { move(from: sender.tag, to: sender.tag - 1) }
    @objc private func moveDown(_ sender: NSButton) { move(from: sender.tag, to: sender.tag + 1) }

    private func move(from: Int, to: Int) {
        guard rules.indices.contains(from), rules.indices.contains(to) else { return }
        rules.swapAt(from, to)
        rebuildRows()
        save()
    }

    @objc private func enabledChanged(_ sender: NSButton) {
        guard rules.indices.contains(sender.tag) else { return }
        rules[sender.tag].enabled = sender.state == .on
        save()
    }

    @objc private func colorChanged(_ sender: NSPopUpButton) {
        guard rules.indices.contains(sender.tag),
              let raw = sender.selectedItem?.representedObject as? String,
              let color = FileColor(rawValue: raw) else { return }
        rules[sender.tag].color = color
        save()
    }

    @objc private func kindChanged(_ sender: NSPopUpButton) {
        guard rules.indices.contains(sender.tag),
              let kind = RuleConditionForm.Kind(rawValue: sender.indexOfSelectedItem) else { return }
        applyForm(RuleConditionForm(kind: kind, value: ""), at: sender.tag)
        rebuildRows()
    }

    @objc private func valueChanged(_ sender: NSTextField) {
        guard rules.indices.contains(sender.tag) else { return }
        var form = drafts[rules[sender.tag].id] ?? RuleConditionForm(rules[sender.tag].condition)
        form.value = sender.stringValue
        applyForm(form, at: sender.tag)
    }

    private func applyForm(_ form: RuleConditionForm, at index: Int) {
        let id = rules[index].id
        guard let condition = form.condition else {
            drafts[id] = form
            return
        }
        drafts[id] = nil
        rules[index].condition = condition
        save()
    }
}
