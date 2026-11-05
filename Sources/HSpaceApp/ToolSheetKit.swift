import AppKit

/// Controls shared by the batch tool sheets, so that they have one look, one font scale and one way to label for VoiceOver.
@MainActor
enum ToolUI {
    static func panel(width: CGFloat, height: CGFloat) -> NSPanel {
        NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                styleMask: [.titled], backing: .buffered, defer: false)
    }

    static func label(_ text: String = "", size: CGFloat = 11, color: NSColor = .secondaryLabelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size)
        label.textColor = color
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }

    static func title(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: 13)
        return label
    }

    static func field(_ value: String = "", placeholder: String, delegate: NSTextFieldDelegate?) -> NSTextField {
        let field = NSTextField(string: value)
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        field.font = .systemFont(ofSize: 11)
        field.controlSize = .small
        field.delegate = delegate
        return field
    }

    static func popup(_ titles: [String], label: String, target: AnyObject?, action: Selector?) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: titles)
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: 11)
        popup.setAccessibilityLabel(label)
        popup.target = target
        popup.action = action
        return popup
    }

    static func check(_ title: String, target: AnyObject?, action: Selector?) -> NSButton {
        let check = NSButton(checkboxWithTitle: title, target: target, action: action)
        check.controlSize = .small
        check.font = .systemFont(ofSize: 11)
        return check
    }

    static func button(_ title: String, target: AnyObject?, action: Selector?) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        return button
    }

    /// A vertical sheet layout: every view spans the width, with the standard 20pt margin.
    static func fill(_ panel: NSPanel, with views: [NSView]) {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        var constraints = [
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ]
        for view in views {
            constraints.append(view.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 20))
            constraints.append(view.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -20))
        }
        NSLayoutConstraint.activate(constraints)
        panel.contentView = root
    }

    /// Right-aligned action buttons, with an optional view on the left.
    static func buttonRow(leading: NSView? = nil, _ buttons: [NSButton]) -> NSStackView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [leading, spacer].compactMap { $0 } + buttons)
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    static func progressBar() -> NSProgressIndicator {
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.controlSize = .small
        bar.isHidden = true
        return bar
    }

    /// Multi-column read-only table in a scroll view. Headers double as the column names VoiceOver reads.
    static func table(columns: [(id: String, title: String, width: CGFloat)], source: NSTableViewDataSource & NSTableViewDelegate,
                      height: CGFloat) -> (scroll: NSScrollView, table: NSTableView) {
        let table = NSTableView()
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 20
        for column in columns {
            let tableColumn = NSTableColumn(identifier: .init(column.id))
            tableColumn.title = column.title
            tableColumn.width = column.width
            table.addTableColumn(tableColumn)
        }
        table.dataSource = source
        table.delegate = source
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: height).isActive = true
        return (scroll, table)
    }

    /// A reusable label cell for `table(columns:...)`.
    static func cell(in table: NSTableView, text: String, color: NSColor = .labelColor) -> NSTextField {
        let id = NSUserInterfaceItemIdentifier("toolCell")
        let label = table.makeView(withIdentifier: id, owner: nil) as? NSTextField ?? {
            let made = NSTextField(labelWithString: "")
            made.identifier = id
            made.font = .systemFont(ofSize: 11)
            made.lineBreakMode = .byTruncatingMiddle
            return made
        }()
        label.stringValue = text
        label.textColor = color
        return label
    }

    static func showError(_ message: String, in window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t("tools.failed")
        alert.informativeText = message
        if let window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
