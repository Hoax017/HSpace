import AppKit
import FileMetadata

/// What the tag picker edits: one row per tag, marked on, off or mixed across the selection. Pure, so it is tested without a window.
struct TagPickerState {
    enum Mark: Equatable { case off, mixed, on }

    struct Row: Equatable {
        let tag: FinderTag
        var mark: Mark
        let original: Mark
    }

    private(set) var rows: [Row]

    /// - Parameters:
    ///   - selection: the current tags of each selected item
    ///   - known: tags offered besides those already on the selection
    init(selection: [[FinderTag]], known: [FinderTag]) {
        let used = TagQuery.known(in: selection)
        let offered = known + used.filter { tag in !known.contains { TagQuery.sameName($0.name, tag.name) } }
        rows = offered.map { tag in
            let holders = selection.filter { list in list.contains { TagQuery.sameName($0.name, tag.name) } }.count
            let mark: Mark = holders == 0 ? .off : (holders == selection.count ? .on : .mixed)
            return Row(tag: tag, mark: mark, original: mark)
        }
    }

    /// A click never lands on mixed: it decides for the whole selection.
    mutating func toggle(_ name: String) {
        guard let index = rows.firstIndex(where: { TagQuery.sameName($0.tag.name, name) }) else { return }
        rows[index].mark = rows[index].mark == .on ? .off : .on
    }

    /// Adds a new tag, marked on. A name already listed is just turned on.
    mutating func add(_ tag: FinderTag) {
        if let index = rows.firstIndex(where: { TagQuery.sameName($0.tag.name, tag.name) }) {
            rows[index].mark = .on
        } else {
            rows.append(Row(tag: tag, mark: .on, original: .off))
        }
    }

    /// Only rows the user changed: a mixed row left alone keeps every item as it was.
    var edit: MetadataEdit? {
        let changed = rows.filter { $0.mark != $0.original }
        guard !changed.isEmpty else { return nil }
        return .tags(add: changed.filter { $0.mark == .on }.map(\.tag),
                     remove: Set(changed.filter { $0.mark == .off }.map(\.tag.name)))
    }

    var newTags: [FinderTag] {
        rows.filter { $0.mark == .on && $0.original == .off }.map(\.tag)
    }
}

/// Sheet with a checkbox per tag and a field for a new one. Native controls, so keyboard and VoiceOver work as usual.
@MainActor
final class TagPickerSheet: NSObject {
    private var state: TagPickerState
    private let onApply: (TagPickerState) -> Void
    private let sheet: NSWindow
    private let list = NSStackView()
    private let nameField = NSTextField()
    private let colorPopup = NSPopUpButton()
    /// Sheets have no owner while open; this keeps the controller alive until it closes
    private static var open: TagPickerSheet?

    private init(state: TagPickerState, title: String, onApply: @escaping (TagPickerState) -> Void) {
        self.state = state
        self.onApply = onApply
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
                         styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        buildContent(title: title)
        rebuildRows()
    }

    static func present(state: TagPickerState, title: String, in window: NSWindow,
                        onApply: @escaping (TagPickerState) -> Void) {
        let picker = TagPickerSheet(state: state, title: title, onApply: onApply)
        open = picker
        window.beginSheet(picker.sheet) { _ in
            MainActor.assumeIsolated { open = nil }
        }
    }

    private func buildContent(title: String) {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13)
        heading.lineBreakMode = .byTruncatingMiddle

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 4
        list.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        list.translatesAutoresizingMaskIntoConstraints = false

        let clip = FlippedView()
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(list)
        let scroll = NSScrollView()
        scroll.documentView = clip
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: clip.topAnchor),
            list.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            clip.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 240),
        ])

        nameField.placeholderString = L10n.t("tags.picker.newPlaceholder")
        nameField.setAccessibilityLabel(L10n.t("tags.picker.newPlaceholder"))
        nameField.target = self
        nameField.action = #selector(addTag(_:))
        for color in TagColor.allCases {
            colorPopup.addItem(withTitle: TagPalette.name(color))
            colorPopup.lastItem?.image = TagPalette.menuImage(color)
            colorPopup.lastItem?.representedObject = color.rawValue
        }
        colorPopup.setAccessibilityLabel(L10n.t("tags.picker.color"))
        let add = NSButton(title: L10n.t("tags.picker.add"), target: self, action: #selector(addTag(_:)))
        let newRow = NSStackView(views: [nameField, colorPopup, add])
        newRow.orientation = .horizontal
        newRow.spacing = 8
        nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let cancel = NSButton(title: L10n.t("common.cancel"), target: self, action: #selector(cancelClicked(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let apply = NSButton(title: L10n.t("tags.picker.apply"), target: self, action: #selector(applyClicked(_:)))
        apply.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, apply])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [heading, scroll, newRow, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -16),
            newRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -16),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -16),
            content.widthAnchor.constraint(equalToConstant: 320),
        ])
        sheet.contentView = content
    }

    private func rebuildRows() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for row in state.rows {
            let box = NSButton(checkboxWithTitle: row.tag.name, target: self, action: #selector(rowToggled(_:)))
            box.allowsMixedState = row.mark == .mixed
            box.state = row.mark == .on ? .on : (row.mark == .mixed ? .mixed : .off)
            box.identifier = NSUserInterfaceItemIdentifier(row.tag.name)
            let dot = NSImageView()
            dot.image = TagPalette.menuImage(row.tag.color)
            dot.setAccessibilityElement(false)
            let line = NSStackView(views: [dot, box])
            line.orientation = .horizontal
            line.spacing = 4
            list.addArrangedSubview(line)
        }
    }

    @objc private func rowToggled(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue else { return }
        state.toggle(name)
        rebuildRows()
    }

    /// Return in the field adds the tag; an empty field means the user is done
    @objc private func addTag(_ sender: Any?) {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            if sender as? NSTextField != nil { applyClicked(sender) }
            return
        }
        let raw = colorPopup.selectedItem?.representedObject as? Int ?? 0
        state.add(FinderTag(name: name.replacingOccurrences(of: "\n", with: " "),
                            color: TagColor(rawValue: raw) ?? .none))
        nameField.stringValue = ""
        rebuildRows()
    }

    @objc private func applyClicked(_ sender: Any?) {
        // A typed name not yet added still counts: nothing the user can see in the field may be dropped
        if !nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { addTag(nil) }
        let final = state
        close()
        onApply(final)
    }

    @objc private func cancelClicked(_ sender: Any?) { close() }

    private func close() {
        sheet.sheetParent?.endSheet(sheet)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
