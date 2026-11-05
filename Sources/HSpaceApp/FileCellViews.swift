import AppKit

/// Table view that reports user interaction (pane focus coordination: a click requests activation of the owning pane).
/// Also hosts the context menu hook and the Return key (triggers inline rename).
@MainActor
final class FocusReportingTableView: NSTableView {
    var onInteract: (() -> Void)?
    /// Context menu provider: the argument is the clicked row (-1 means empty space, using the directory-level menu)
    var menuProvider: ((Int) -> NSMenu?)?
    /// Return key: starts inline rename of the selected row
    var onReturn: (() -> Void)?
    /// Return key (when enterAction=open): opens the selected item
    var onOpenSelected: (() -> Void)?
    /// Backspace key (no ⌘): dispatches by backspaceAction (ignore/back/trash/up)
    var onBackspaceAction: (() -> Void)?
    /// Space key: toggles Quick Look preview (Finder muscle memory)
    var onSpace: (() -> Void)?
    /// Drag exited/ended (cancels the spring-loaded timer)
    var onDragExited: (() -> Void)?
    /// ←/→ keys (moving between columns in column view; nil hands back to system default behaviour)
    var onArrowLeft: (() -> Void)?
    var onArrowRight: (() -> Void)?
    /// Group header check (M26): true means the row is a group header; clicking toggles collapse and takes no part in selection
    var isGroupRowProvider: ((Int) -> Bool)?
    /// Group header click (M26): toggles the collapse state of the row's group
    var onGroupRowClick: ((Int) -> Void)?

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onDragExited?()
        super.draggingExited(sender)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        onDragExited?()
        super.draggingEnded(sender)
    }

    /// I-43: whether a drag started during this super.mouseDown (set by the delegate's pasteboardWriterForRow).
    /// Distinguishes "plain click on a selected row" (collapse early) from "dragging a multi-selection" (selection stays).
    var dragInitiated = false

    /// Click on an already selected item → rename (user report: only Enter could trigger it).
    /// `onSingleClickRename` is wired to beginRename(row:) by FileListViewController.
    var onSingleClickRename: ((Int) -> Void)?
    /// Pending rename (waits one double-click interval; a double click voids it)
    private var pendingRenameToken = 0

    /// Decision predicate for click-to-rename (pure function, deterministically unit-testable).
    /// Only "**exactly one selected** + click on that selected row + no modifiers + single click" qualifies.
    /// Why multi-selection is excluded: that gesture belongs to I-43's "collapse selection early"; when the two compete, collapsing wins,
    /// since collapsing is itself a selection change and an immediate rename field would be jarring.
    static func shouldScheduleRename(clickedRow: Int, modifiers: NSEvent.ModifierFlags,
                                     clickCount: Int, selectedCount: Int,
                                     rowIsSelected: Bool, isGroupRow: Bool) -> Bool {
        clickedRow >= 0
            && !isGroupRow
            && modifiers.intersection([.command, .shift, .option, .control]).isEmpty
            && clickCount == 1
            && selectedCount == 1
            && rowIsSelected
    }

    /// Cancels a pending rename (double click, navigation and keyboard actions must all void it)
    func cancelPendingRename() { pendingRenameToken += 1 }

    /// I-43 decision predicate (pure function, deterministically unit-testable): whether to collapse the selection to one row right after super.mouseDown.
    /// True only for "no modifiers + single click (not double) + current multi-selection + click on a selected row", the case where AppKit waits out the double-click interval.
    static func shouldPreemptCollapse(clickedRow: Int, modifiers: NSEvent.ModifierFlags,
                                      clickCount: Int, selectedCount: Int, rowIsSelected: Bool) -> Bool {
        clickedRow >= 0
            && modifiers.intersection([.command, .shift, .option, .control]).isEmpty
            && clickCount == 1
            && selectedCount > 1
            && rowIsSelected
    }

    override func mouseDown(with event: NSEvent) {
        onInteract?()
        // Group header row: unselectable and non-collapsible; swallow the click (keep it out of super's selection chain,
        // otherwise the selection "jumps" to the row below the header)
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0, isGroupRowProvider?(row) == true { return }
        // I-43: on a plain click on a selected row in a multi-selection, AppKit waits the double-click interval (~0.5s NSEvent.doubleClickInterval) before
        // collapsing to a single selection (to allow for double-click open), so clicks inside the selection stalled 0.5-1s while clicks outside were instant (instrumented on a real machine: 0.672s).
        // Let super handle it normally (drag/double-click semantics unaffected); if no drag started meanwhile (pasteboardWriterForRow not called),
        // collapse to single selection right after super returns, removing the wait (measured down to 0.160s). The target row matches AppKit's delayed collapse.
        if Self.shouldPreemptCollapse(clickedRow: row, modifiers: event.modifierFlags,
                                      clickCount: event.clickCount,
                                      selectedCount: selectedRowIndexes.count,
                                      rowIsSelected: selectedRowIndexes.contains(row)) {
            dragInitiated = false
            super.mouseDown(with: event)
            if !dragInitiated {
                selectRowIndexes([row], byExtendingSelection: false)
            }
            return
        }
        // Double click: void the pending rename (otherwise the rename field appears, then "open" displaces it, and the two actions fight)
        if event.clickCount >= 2 { cancelPendingRename() }

        // Click on a selected item → rename. Must **wait out a double-click interval** first:
        // renaming at once would flash the rename field when the user meant to double-click in.
        let willScheduleRename = Self.shouldScheduleRename(
            clickedRow: row, modifiers: event.modifierFlags, clickCount: event.clickCount,
            selectedCount: selectedRowIndexes.count,
            rowIsSelected: selectedRowIndexes.contains(row),
            isGroupRow: row >= 0 && isGroupRowProvider?(row) == true)

        super.mouseDown(with: event)

        if willScheduleRename, let fire = onSingleClickRename {
            pendingRenameToken += 1
            let token = pendingRenameToken
            let delay = NSEvent.doubleClickInterval
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.pendingRenameToken == token else { return }   // Voided by a double click/navigation in the meantime
                guard self.selectedRowIndexes.count == 1,
                      self.selectedRowIndexes.contains(row) else { return }        // Selection changed, do nothing
                fire(row)
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        cancelPendingRename()
        onInteract?()
        super.rightMouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        onInteract?()
        return super.becomeFirstResponder()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onInteract?()
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        // Right-click on a group header: leaves the selection alone (headers are unselectable) and asks menuProvider for the group filter menu
        if row >= 0, isGroupRowProvider?(row) == true {
            return menuProvider?(row)
        }
        // Right-clicking an unselected row → make it the only selection first (Finder semantics)
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes([row], byExtendingSelection: false)
        }
        return menuProvider?(row)
    }

    override func keyDown(with event: NSEvent) {
        cancelPendingRename()   // Any key voids "pending click-to-rename", so an input field can't pop up mid-typing
        // Plain ⌘↑/⌘↓ reaching the table = navigation menu not wired (disabled state): swallow it, so the default "jump selection" can't replace navigation semantics (I-39);
        // combos with ⇧/⌥/⌃ (such as ⇧⌘↓ to extend the selection) aren't swallowed and keep system behaviour
        if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
           event.keyCode == 125 || event.keyCode == 126 { return }
        // Return (36) / Enter (76): dispatch by usage preference (rename → inline rename / open → open selected)
        if event.keyCode == 36 || event.keyCode == 76 {
            if Preferences.enterAction == "open" { onOpenSelected?() } else { onReturn?() }
            return
        }
        // Backspace (51): ⌘⌫ keeps trash semantics and goes back to the menu shortcut; without ⌘, dispatch by usage preference
        if event.keyCode == 51 {
            if event.modifierFlags.contains(.command) {
                super.keyDown(with: event)
            } else {
                onBackspaceAction?()
            }
            return
        }
        if event.keyCode == 49, let onSpace {
            onSpace()
            return
        }
        // ← (123) / → (124): column view takes over moving between columns; otherwise back to default
        if event.keyCode == 123, let onArrowLeft {
            onArrowLeft()
            return
        }
        if event.keyCode == 124, let onArrowRight {
            onArrowRight()
            return
        }
        super.keyDown(with: event)
    }
}

/// Inline rename field: Enter commits, Esc cancels, losing focus commits; can select just the base name (excluding the extension)
@MainActor
final class InlineRenameField: NSTextField, NSTextFieldDelegate {
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    private var finished = false

    init(string: String) {
        super.init(frame: .zero)
        stringValue = string
        isEditable = true
        isBordered = true
        isBezeled = true
        bezelStyle = .squareBezel
        drawsBackground = true
        font = .systemFont(ofSize: Formatters.listFontSize)
        lineBreakMode = .byTruncatingTail
        focusRingType = .default
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    /// Selects the base name (leaves the extension unselected); selects everything if there is no extension
    func selectBaseName() {
        guard let editor = currentEditor() else { return }
        let ns = stringValue as NSString
        let base = ns.deletingPathExtension
        if base.count > 0, base.count < ns.length {
            editor.selectedRange = NSRange(location: 0, length: base.count)
        } else {
            editor.selectAll(nil)
        }
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { commit(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { cancel(); return true }
        return false
    }

    /// Losing focus = commit (Finder semantics)
    func controlTextDidEndEditing(_ obj: Notification) {
        guard !finished else { return }
        commit()
    }

    private func commit() { guard !finished else { return }; finished = true; onCommit?(stringValue) }
    private func cancel() { guard !finished else { return }; finished = true; onCancel?() }
}

/// Name cell: icon + text; supports inline rename (label ⟷ editable field)
@MainActor
final class NameCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let tagDots = TagDotsView()
    private var editor: InlineRenameField?
    private var baseInk = NSColor.labelColor
    private var tint: NSColor?

    /// Commit/cancel callbacks (injected by FileListViewController, wired to the .rename submission and FG-6 rollback)
    var onRenameCommit: ((String) -> Void)?
    var onRenameCancel: (() -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: 12)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        tagDots.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        addSubview(label)
        addSubview(tagDots)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: tagDots.leadingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            tagDots.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            tagDots.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = label
        imageView = iconView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    func configure(icon: NSImage, name: String, dimmed: Bool) {
        iconView.image = icon
        label.stringValue = name
        label.font = .systemFont(ofSize: Formatters.listFontSize)  // Re-read the font size on each configure (takes effect at once on column rebuild)
        baseInk = dimmed ? .secondaryLabelColor : .labelColor
        tint = nil
        applyInk()
    }

    /// Call after `configure`, and on its own when only the decoration changed (keeps a rename in progress)
    func decorate(_ decoration: FileDecoration) {
        tagDots.show(decoration.tags)
        tint = decoration.tint
        if let icon = decoration.icon { iconView.image = icon }
        applyInk()
    }

    /// A selected row keeps the system's ink: a coloured name on the selection highlight would be hard to read
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyInk() }
    }

    private func applyInk() {
        label.textColor = backgroundStyle == .emphasized ? baseInk : (tint ?? baseInk)
    }

    var isEditing: Bool { editor != nil }

    /// Enters inline editing: hides the label, overlays an editable field, selects the base name
    func beginRename() {
        guard editor == nil, let win = window else { return }
        let field = InlineRenameField(string: label.stringValue)
        field.onCommit = { [weak self] newName in self?.finish(commit: newName) }
        field.onCancel = { [weak self] in self?.finish(commit: nil) }
        field.translatesAutoresizingMaskIntoConstraints = false
        editor = field
        label.isHidden = true
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        win.makeFirstResponder(field)
        field.selectBaseName()
    }

    private func finish(commit: String?) {
        let field = editor
        editor = nil
        field?.removeFromSuperview()
        label.isHidden = false
        if let name = commit { onRenameCommit?(name) } else { onRenameCancel?() }
    }
}

/// Group header row view (M26 list grouping): disclosure triangle + "Aug 2026" + item count (tabular-nums, secondary ink).
/// The whole row is clickable to toggle collapse (onToggle); the context menu is dispatched per row type by the table view's menuProvider.
/// Row height 24 and floatsGroupRows floating are configured by FileListViewController.
@MainActor
final class GroupHeaderView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")

    /// A group header is a **title printed on a background strip**, not a control to expand or collapse (owner request: like QSpace, no folding).
    /// The chevron and folding were removed: an arrow that looks like a button but does nothing
    /// is worse than no arrow, since it promises something it can't do.
    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        wantsLayer = true
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)  // tabular-nums
        addSubview(titleLabel)
        addSubview(countLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    func configure(title: String, count: Int) {
        titleLabel.stringValue = title
        countLabel.stringValue = L10n.f("group.count", count)
    }
}

/// Plain text cell (date/size/kind)
@MainActor
final class TextCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    /// Plain text (kind column etc); the date column passes monospacedDigits=true → tabular digits, no jitter on refresh (Tufte)
    func configure(_ text: String, alignment: NSTextAlignment, monospacedDigits: Bool = false) {
        let size = Formatters.listFontSize  // Re-read the font size on each configure (takes effect at once on column rebuild)
        label.stringValue = text
        label.textColor = .secondaryLabelColor  // Reset on cell reuse (the size column may have left attributed/labelColor last time)
        label.font = monospacedDigits
            ? .monospacedDigitSystemFont(ofSize: size, weight: .regular)
            : .systemFont(ofSize: size)
        label.alignment = alignment
    }

    /// Size column: value in labelColor + unit in secondaryLabelColor (three-tier ink, gray unit recedes), tabular digits.
    func configureSize(value: String, unit: String, alignment: NSTextAlignment) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: Formatters.listFontSize, weight: .regular)
        // I-34: no wrapping in narrow columns ("151.4 MB" on two lines would overflow the 22pt row): single line + head truncation keeps the unit visible
        label.usesSingleLineMode = true
        label.lineBreakMode = .byTruncatingHead
        let s = NSMutableAttributedString(string: value,
            attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        if !unit.isEmpty {
            s.append(NSAttributedString(string: " " + unit,
                attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        label.attributedStringValue = s
        label.alignment = alignment
    }
}

/// Scroll view whose bottom margin takes right-clicks: the strip reserved by `contentInsets.bottom` falls on the clip view,
/// the table view gets no clicks there, and the event bubbles up to this layer, which shows the directory-level menu.
///
/// Why not add a few fake blank rows: that would pollute the table's data source, and row count, selection and group counts would all have to lie.
@MainActor
final class BlankAreaScrollView: NSScrollView {
    /// Right-click on empty space → directory-level menu (provided by FileListViewController, same one as clickedRow: -1)
    var onBlankMenu: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        onBlankMenu?() ?? super.menu(for: event)
    }
}
