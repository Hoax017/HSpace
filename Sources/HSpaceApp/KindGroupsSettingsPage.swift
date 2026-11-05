import AppKit
import FileMetadata

/// One text field stands for both lists of a group: entries with a dot are system types, the others are extensions.
enum KindGroupMatches {
    static func text(for group: KindGroup) -> String {
        (group.typeIDs + group.extensions).joined(separator: ", ")
    }

    static func apply(_ text: String, to group: inout KindGroup) {
        let parts = text.split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { $0.hasPrefix(".") ? String($0.dropFirst()) : String($0) }
            .filter { !$0.isEmpty }
        group.typeIDs = parts.filter { $0.contains(".") }
        group.extensions = parts.filter { !$0.contains(".") }
    }
}

/// Manager for kind groups: rename, change what matches, reorder, add, remove and reset. Changes apply at once.
@MainActor
final class KindGroupsSettingsPage: NSObject, SettingsPage {
    var pageTitleKey: String { "settings.tab.kindGroups" }

    private let rows = NSStackView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var groups: [KindGroup] = []

    func makeView() -> NSView {
        groups = MetadataSettings.kindGroups
        let note = NSTextField(wrappingLabelWithString: L10n.t("settings.kind.note"))
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 4
        rebuildRows()

        let add = NSButton(title: L10n.t("settings.kind.add"), target: self, action: #selector(addGroup(_:)))
        let reset = NSButton(title: L10n.t("settings.kind.reset"), target: self, action: #selector(resetGroups(_:)))
        let actions = NSStackView(views: [add, reset])
        actions.orientation = .horizontal
        actions.spacing = 8
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true

        let stack = NSStackView(views: [note, rows, actions, errorLabel])
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
        for (index, group) in groups.enumerated() {
            let name = NSTextField(string: group.name)
            name.tag = index
            name.target = self
            name.action = #selector(nameChanged(_:))
            name.placeholderString = L10n.t("settings.kind.name")
            name.setAccessibilityLabel(L10n.t("settings.kind.name"))
            name.widthAnchor.constraint(equalToConstant: 112).isActive = true

            let matches = NSTextField(string: KindGroupMatches.text(for: group))
            matches.tag = index
            matches.target = self
            matches.action = #selector(matchesChanged(_:))
            matches.placeholderString = L10n.t("settings.kind.matches")
            matches.setAccessibilityLabel(L10n.t("settings.kind.matches"))
            matches.widthAnchor.constraint(equalToConstant: 240).isActive = true

            let up = iconButton("chevron.up", "settings.rule.up", #selector(moveUp(_:)), tag: index)
            up.isEnabled = index > 0
            let down = iconButton("chevron.down", "settings.rule.down", #selector(moveDown(_:)), tag: index)
            down.isEnabled = index < groups.count - 1
            let remove = iconButton("minus.circle", "settings.kind.remove", #selector(removeGroup(_:)), tag: index)

            let line = NSStackView(views: [name, matches, up, down, remove])
            line.orientation = .horizontal
            line.spacing = 8
            rows.addArrangedSubview(line)
        }
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
        let snapshot = groups
        Task {
            let problem = await MetadataSettings.setKindGroups(snapshot)
            errorLabel.stringValue = problem ?? ""
            errorLabel.isHidden = problem == nil
        }
    }

    @objc private func nameChanged(_ sender: NSTextField) {
        let name = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard groups.indices.contains(sender.tag), !name.isEmpty else {
            // A group needs a name to show as a header
            if groups.indices.contains(sender.tag) { sender.stringValue = groups[sender.tag].name }
            return
        }
        groups[sender.tag].name = name
        save()
    }

    @objc private func matchesChanged(_ sender: NSTextField) {
        guard groups.indices.contains(sender.tag) else { return }
        KindGroupMatches.apply(sender.stringValue, to: &groups[sender.tag])
        save()
    }

    @objc private func addGroup(_ sender: Any?) {
        groups.append(KindGroup(name: L10n.t("settings.kind.newName")))
        rebuildRows()
        save()
    }

    @objc private func removeGroup(_ sender: NSButton) {
        guard groups.indices.contains(sender.tag) else { return }
        groups.remove(at: sender.tag)
        rebuildRows()
        save()
    }

    @objc private func moveUp(_ sender: NSButton) { move(from: sender.tag, to: sender.tag - 1) }
    @objc private func moveDown(_ sender: NSButton) { move(from: sender.tag, to: sender.tag + 1) }

    private func move(from: Int, to: Int) {
        guard groups.indices.contains(from), groups.indices.contains(to) else { return }
        groups.swapAt(from, to)
        rebuildRows()
        save()
    }

    /// Replaces the user's list, so it asks first
    @objc private func resetGroups(_ sender: NSButton) {
        guard let window = sender.window else { return }
        let alert = NSAlert()
        alert.messageText = L10n.t("settings.kind.resetTitle")
        alert.informativeText = L10n.t("settings.kind.resetBody")
        alert.addButton(withTitle: L10n.t("common.cancel"))
        alert.addButton(withTitle: L10n.t("settings.kind.reset"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.groups = KindGroups.defaults(localized: { L10n.t($0) })
                self.rebuildRows()
                self.save()
            }
        }
    }
}
