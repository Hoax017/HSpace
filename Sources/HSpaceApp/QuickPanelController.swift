import AppKit

/// What a quick panel offers. `rows` runs on every keystroke, so it must not touch the disk.
struct QuickPanelContent {
    let placeholder: String
    let rows: (String) -> [QuickRow]
    /// Runs after the panel is gone, with the modifiers held when the row was chosen
    let choose: (QuickRow, NSEvent.ModifierFlags) -> Void
    var onClose: () -> Void = {}
}

/// Search field over a list, floating on the main window: quick locations, go to bookmark, quick launcher.
/// Keyboard first: type to filter, arrows move, Return chooses, Esc closes. Any other click closes it.
@MainActor
final class QuickPanelController: NSObject {
    static let shared = QuickPanelController()
    private static let width: CGFloat = 520
    private static let fieldHeight: CGFloat = 28

    private let field = NSTextField()
    private let list = QuickListView()
    private let emptyLabel = NSTextField(labelWithString: L10n.t("quick.empty"))
    private var content: QuickPanelContent?
    private weak var parentWindow: NSWindow?
    private var resignObserver: (any NSObjectProtocol)?

    private lazy var panel: QuickPanelSurface = {
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.delegate = self
        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.textColor = .tertiaryLabelColor
        list.onActivate = { [weak self] row in self?.choose(row: row, modifiers: NSEvent.modifierFlags) }
        let separator = NSBox()
        separator.boxType = .separator
        let root = NSView()
        for sub in [field, separator, list, emptyLabel] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: root.topAnchor),
            field.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            field.heightAnchor.constraint(equalToConstant: Self.fieldHeight),
            separator.topAnchor.constraint(equalTo: field.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            list.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4),
            list.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: list.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: list.centerYAnchor),
        ])
        let surface = QuickPanelSurface(width: Self.width, content: root)
        surface.acceptsKey = true
        surface.onCancel = { [weak self] in self?.close() }
        return surface
    }()

    var isVisible: Bool { content != nil }
    var rows: [QuickRow] { list.rows }
    var selectedRow: QuickRow? { list.rows.indices.contains(list.selectedIndex) ? list.rows[list.selectedIndex] : nil }
    var showsEmptyMessage: Bool { !emptyLabel.isHidden }
    var query: String { field.stringValue }

    func show(_ content: QuickPanelContent, over window: NSWindow?) {
        close()
        self.content = content
        parentWindow = window
        _ = panel
        field.stringValue = ""
        field.placeholderString = content.placeholder
        field.setAccessibilityLabel(content.placeholder)
        reload(keeping: nil)
        place()
        panel.makeFirstResponder(field)
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    /// The offer changed while open: the highlight stays on its row
    func refresh() {
        guard isVisible else { return }
        reload(keeping: selectedRow?.id)
        place()
    }

    func close() {
        guard let content else { return }
        self.content = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        panel.dismiss()
        parentWindow?.makeKeyAndOrderFront(nil)
        content.onClose()
    }

    func setQuery(_ text: String) {
        field.stringValue = text
        queryChanged()
    }

    func moveSelection(by offset: Int) { list.moveSelection(by: offset) }

    func chooseSelected(modifiers: NSEvent.ModifierFlags) {
        choose(row: list.selectedIndex, modifiers: modifiers)
    }

    private func choose(row index: Int, modifiers: NSEvent.ModifierFlags) {
        guard let content else { return }
        guard list.rows.indices.contains(index) else { NSSound.beep(); return }
        let row = list.rows[index]
        close()
        content.choose(row, modifiers)
    }

    private func queryChanged() {
        reload(keeping: nil)
        place()
    }

    private func reload(keeping id: String?) {
        guard let content else { return }
        let rows = content.rows(field.stringValue)
        list.show(rows, selected: id.flatMap { id in rows.firstIndex { $0.id == id } } ?? 0)
        emptyLabel.isHidden = !rows.isEmpty
    }

    private func place() {
        let height = Self.fieldHeight + 4 + QuickListView.height(for: list.rows.count)
        panel.present(over: parentWindow, height: height, makeKey: true)
    }
}

extension QuickPanelController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) { queryChanged() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)): moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)): moveSelection(by: 1)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            chooseSelected(modifiers: NSApp.currentEvent?.modifierFlags ?? [])
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }
}
