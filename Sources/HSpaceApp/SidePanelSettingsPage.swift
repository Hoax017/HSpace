import AppKit
import SidePanel

/// Chooses and orders the side panel's actions. Changes apply at once.
@MainActor
final class SidePanelSettingsPage: NSObject, SettingsPage {
    var pageTitleKey: String { "settings.tab.sidePanel" }

    private let rows = NSStackView()
    private var list = PanelAction.list()

    func makeView() -> NSView {
        list = PanelAction.list()
        let note = NSTextField(wrappingLabelWithString: L10n.t("settings.sidePanel.note"))
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 4
        rebuildRows()
        let reset = NSButton(title: L10n.t("settings.sidePanel.reset"), target: self, action: #selector(resetList(_:)))

        let stack = NSStackView(views: [note, rows, reset])
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
        for (index, id) in list.all.enumerated() {
            guard let action = PanelAction.action(id) else { continue }
            rows.addArrangedSubview(row(action, index: index))
        }
    }

    private func row(_ action: PanelAction, index: Int) -> NSView {
        let title = L10n.t(action.titleKey)
        let check = ToolUI.check(title, target: self, action: #selector(toggled(_:)))
        check.state = list.isEnabled(action.id) ? .on : .off
        check.identifier = NSUserInterfaceItemIdentifier(action.id)
        let up = moveButton("chevron.up", L10n.f("settings.sidePanel.up", title), action.id, #selector(moveUp(_:)))
        up.isEnabled = index > 0
        let down = moveButton("chevron.down", L10n.f("settings.sidePanel.down", title), action.id, #selector(moveDown(_:)))
        down.isEnabled = index < list.all.count - 1
        check.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let row = NSStackView(views: [check, up, down])
        row.orientation = .horizontal
        row.spacing = 4
        return row
    }

    private func moveButton(_ symbol: String, _ label: String, _ id: String, _ selector: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(),
                              target: self, action: selector)
        button.isBordered = false
        button.setAccessibilityLabel(label)
        button.toolTip = label
        button.identifier = NSUserInterfaceItemIdentifier(id)
        return button
    }

    private func commit() {
        Preferences.panelActions = list.enabled
        NotificationCenter.default.post(name: .hspacePanelActionsChanged, object: nil)
        rebuildRows()
    }

    @objc private func toggled(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        list.set(id, enabled: sender.state == .on)
        commit()
    }

    @objc private func moveUp(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        list.move(id, by: -1)
        commit()
    }

    @objc private func moveDown(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        list.move(id, by: 1)
        commit()
    }

    @objc private func resetList(_ sender: Any?) {
        Preferences.panelActions = nil
        list = PanelAction.list()
        NotificationCenter.default.post(name: .hspacePanelActionsChanged, object: nil)
        rebuildRows()
    }
}
