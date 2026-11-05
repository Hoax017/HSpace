import AppKit
import HiddenRules
import HSpaceContracts

/// App-wide hidden item rules. Listings ask for the set on every snapshot, so it is kept ready.
@MainActor
enum HiddenItems {
    /// A variable so that tests can give it a directory of their own
    static var store: any HiddenRuleStoring = HiddenRuleStore(directory: AppDelegate.supportDirectory) {
        didSet { ruleSet = HiddenRuleSet(store.rules()) }
    }
    private(set) static var ruleSet = HiddenRuleSet(store.rules())

    /// Saves, then has every open view list again
    static func save(_ rules: [HiddenRule]) throws {
        try store.save(rules)
        ruleSet = HiddenRuleSet(rules)
        NotificationCenter.default.post(name: .hspaceHiddenRulesChanged, object: nil)
    }

    /// Drops what the rules hide. With hidden files showing, a hide rule's items stay, dimmed like any hidden item.
    static func filter(_ items: [FileItem], includeHidden: Bool) -> [FileItem] {
        guard !ruleSet.isEmpty else { return items }
        return items.compactMap { item in
            switch ruleSet.verdict(path: item.url.standardizedFileURL.path, isFolder: item.isDirectory && !item.isPackage) {
            case .show: return item
            case .exclude: return nil
            case .hide: return includeHidden ? item.markedHidden : nil
            }
        }
    }
}

private extension FileItem {
    var markedHidden: FileItem {
        FileItem(url: url, name: name, isDirectory: isDirectory, isPackage: isPackage, isSymlink: isSymlink, isHidden: true,
                 size: size, modified: modified, created: created, added: added, contentTypeID: contentTypeID)
    }
}

extension Notification.Name {
    static let hspaceHiddenRulesChanged = Notification.Name("hspaceHiddenRulesChanged")
}

extension MainWindowController {
    /// Hides the selection, one rule per item, undoably
    @objc func hideSelection(_ sender: Any?) {
        let items = grid.activePane.currentSelectedItems()
        guard !items.isEmpty else { NSSound.beep(); return }
        let added = items.map { HiddenRule.exact($0.url, isDirectory: $0.isDirectory && !$0.isPackage) }
        do {
            try HiddenItems.save(HiddenItems.store.rules() + added)
        } catch {
            ToolUI.showError(error.localizedDescription, in: window)
            return
        }
        registerUndoOfHiding(Set(added.map(\.id)))
        Toast.show(L10n.t("toast.itemsHidden"), in: window)
    }

    private func registerUndoOfHiding(_ ids: Set<UUID>) {
        coordinator.undoManager.registerUndo(withTarget: self) { window in
            MainActor.assumeIsolated {
                do {
                    try HiddenItems.save(HiddenItems.store.rules().filter { !ids.contains($0.id) })
                } catch {
                    ToolUI.showError(error.localizedDescription, in: window.window)
                }
            }
        }
        coordinator.undoManager.setActionName(L10n.t("menu.hideItems"))
    }
}

/// Manager for the rules. Changes apply at once. A row that cannot be saved says so and keeps what was typed.
@MainActor
final class HiddenItemsSettingsPage: NSObject, SettingsPage, NSTextFieldDelegate {
    var pageTitleKey: String { "settings.tab.hiddenItems" }

    private let rows = NSStackView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var rules: [HiddenRule] = []

    func makeView() -> NSView {
        rules = HiddenItems.store.rules()
        let note = NSTextField(wrappingLabelWithString: L10n.t("settings.hidden.note"))
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 4
        rebuildRows()
        let add = NSButton(title: L10n.t("settings.hidden.add"), target: self, action: #selector(addRule(_:)))
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
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        ])
        return container
    }

    private func rebuildRows() {
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, rule) in rules.enumerated() { rows.addArrangedSubview(row(rule, index: index)) }
    }

    private func row(_ rule: HiddenRule, index: Int) -> NSView {
        let on = ToolUI.check("", target: self, action: #selector(enabledChanged(_:)))
        on.state = rule.isEnabled ? .on : .off
        on.tag = index
        on.setAccessibilityLabel(L10n.f("settings.hidden.enable", rule.pattern))
        let pattern = ToolUI.field(rule.pattern, placeholder: L10n.t("settings.hidden.pattern"), delegate: self)
        pattern.tag = index
        pattern.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let scope = ToolUI.field(rule.scope ?? "", placeholder: L10n.t("settings.hidden.everywhere"), delegate: self)
        scope.tag = index
        scope.identifier = NSUserInterfaceItemIdentifier("scope")
        scope.widthAnchor.constraint(equalToConstant: 140).isActive = true
        let effect = ToolUI.popup(HiddenRuleEffect.allCases.map { L10n.t("settings.hidden.effect.\($0.rawValue)") },
                                  label: L10n.t("settings.hidden.effect"), target: self, action: #selector(effectChanged(_:)))
        effect.selectItem(at: HiddenRuleEffect.allCases.firstIndex(of: rule.effect) ?? 0)
        effect.tag = index
        let target = ToolUI.popup(HiddenRuleTarget.allCases.map { L10n.t("settings.hidden.target.\($0.rawValue)") },
                                  label: L10n.t("settings.hidden.target"), target: self, action: #selector(targetChanged(_:)))
        target.selectItem(at: HiddenRuleTarget.allCases.firstIndex(of: rule.target) ?? 0)
        target.tag = index
        let label = L10n.f("settings.hidden.remove", rule.pattern)
        let remove = NSButton(image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: label) ?? NSImage(),
                              target: self, action: #selector(removeRule(_:)))
        remove.isBordered = false
        remove.toolTip = label
        remove.setAccessibilityLabel(label)
        remove.tag = index
        let row = NSStackView(views: [on, pattern, scope, effect, target, remove])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    /// Returns whether it landed
    @discardableResult
    private func commit() -> Bool {
        do {
            try HiddenItems.save(rules)
            errorLabel.isHidden = true
            return true
        } catch {
            errorLabel.stringValue = error.localizedDescription
            errorLabel.isHidden = false
            return false
        }
    }

    @objc private func addRule(_ sender: Any?) {
        // Saved once it has a pattern, by the end of editing
        rules.append(HiddenRule(pattern: ""))
        rebuildRows()
    }

    @objc private func removeRule(_ sender: NSButton) {
        guard rules.indices.contains(sender.tag) else { return }
        rules.remove(at: sender.tag)
        commit()
        rebuildRows()
    }

    @objc private func enabledChanged(_ sender: NSButton) {
        guard rules.indices.contains(sender.tag) else { return }
        rules[sender.tag].isEnabled = sender.state == .on
        commit()
    }

    @objc private func effectChanged(_ sender: NSPopUpButton) {
        guard rules.indices.contains(sender.tag) else { return }
        rules[sender.tag].effect = HiddenRuleEffect.allCases[sender.indexOfSelectedItem]
        commit()
    }

    @objc private func targetChanged(_ sender: NSPopUpButton) {
        guard rules.indices.contains(sender.tag) else { return }
        rules[sender.tag].target = HiddenRuleTarget.allCases[sender.indexOfSelectedItem]
        commit()
    }

    func controlTextDidEndEditing(_ note: Notification) {
        guard let field = note.object as? NSTextField, rules.indices.contains(field.tag) else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        if field.identifier?.rawValue == "scope" {
            rules[field.tag].scope = text.isEmpty ? nil : (text as NSString).expandingTildeInPath
        } else {
            rules[field.tag].pattern = text
        }
        commit()
    }
}
