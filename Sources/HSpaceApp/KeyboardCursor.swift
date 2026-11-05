import AppKit
import KeyboardSelection
import QuickLookUI

/// Decides what a press of Space means, from the event being handled
@MainActor
enum SpaceKey {
    static var togglesSelection: Bool {
        let event = NSApp.currentEvent
        let preview = QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared()?.isVisible == true
        return SpaceRole.role(settingOn: Preferences.spaceSelects,
                              isSpaceKeyPress: event?.type == .keyDown && event?.keyCode == 49,
                              hasModifiers: !(event?.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty ?? true),
                              previewShowing: preview) == .toggleSelection
    }
}

/// The outline around the item Space will toggle. The selection cannot show this: the item may well be unselected.
/// Takes no clicks, and draws only while keyboard selection is under way.
final class KeyboardCursorView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.cornerRadius = 2
        layer?.zPosition = 10
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.borderColor = NSColor.keyboardFocusIndicatorColor.cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(around rect: NSRect?, in host: NSView) {
        guard let rect else {
            isHidden = true
            return
        }
        if superview !== host { host.addSubview(self) }
        frame = rect
        isHidden = false
        needsDisplay = true
    }
}

/// Keyboard selection in the table views of the list and column modes
extension FocusReportingTableView {
    /// Space: toggles the item at the cursor and moves on
    func toggleSelectionAtCursor() {
        let isItem = { [self] (row: Int) in !(isGroupRowProvider?(row) ?? false) }
        let last = selectedRow >= 0 ? selectedRow : nil
        guard let step = KeyboardSelection.step(cursor: keyboardCursorRow, lastSelected: last,
                                                count: numberOfRows, isItem: isItem) else { return }
        isTogglingFromKeyboard = true
        if isRowSelected(step.toggle) {
            deselectRow(step.toggle)
        } else {
            selectRowIndexes([step.toggle], byExtendingSelection: true)
        }
        isTogglingFromKeyboard = false
        keyboardCursorRow = step.next
        scrollRowToVisible(step.next)
    }

    /// ↑/↓ while the cursor shows: moves it and leaves the selection as built. Returns false to let the key through.
    func moveKeyboardCursor(with event: NSEvent) -> Bool {
        guard let cursor = keyboardCursorRow, event.keyCode == 125 || event.keyCode == 126,
              event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty else { return false }
        keyboardCursorRow = KeyboardSelection.move(cursor: cursor, by: event.keyCode == 125 ? 1 : -1, count: numberOfRows) {
            !(isGroupRowProvider?($0) ?? false)
        }
        if let row = keyboardCursorRow { scrollRowToVisible(row) }
        return true
    }

    /// Any other change to the selection ends keyboard selection
    func noteSelectionChanged() {
        if !isTogglingFromKeyboard { keyboardCursorRow = nil }
    }

    func placeKeyboardCursor() {
        guard let row = keyboardCursorRow, row < numberOfRows else {
            keyboardCursorView.show(around: nil, in: self)
            return
        }
        keyboardCursorView.show(around: rect(ofRow: row).insetBy(dx: 1, dy: 0.5), in: self)
    }
}
