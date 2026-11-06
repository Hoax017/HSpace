import AppKit

/// One line of a quick panel
struct QuickRow: Equatable {
    let id: String
    let title: String
    var subtitle = ""
    let symbol: String
    /// Quiet text at the end of the row, such as a shortcut
    var trailing = ""
    /// A chosen sidebar colour, which the row keeps here
    var tint: NSColor?
}

/// The list inside the quick panels: a highlighted row driven from outside, since the keyboard stays with the search
/// field or the main window. A click activates the row.
@MainActor
final class QuickListView: NSView {
    static let rowHeight: CGFloat = 36
    static let visibleRows = 8

    var onActivate: ((Int) -> Void)?
    private(set) var rows: [QuickRow] = []
    private let table = QuickTableView()
    private let scroll = NSScrollView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let column = NSTableColumn(identifier: .init("main"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    var selectedIndex: Int { table.selectedRow }

    func show(_ rows: [QuickRow], selected: Int = 0) {
        self.rows = rows
        table.reloadData()
        select(selected)
    }

    func select(_ index: Int) {
        guard rows.indices.contains(index) else { table.deselectAll(nil); return }
        table.selectRowIndexes([index], byExtendingSelection: false)
        table.scrollRowToVisible(index)
    }

    /// Moves the highlight, stopping at both ends
    func moveSelection(by offset: Int) {
        guard !rows.isEmpty else { return }
        select(min(rows.count - 1, max(0, selectedIndex + offset)))
    }

    /// Height that fits `count` rows
    static func height(for count: Int) -> CGFloat {
        rowHeight * CGFloat(min(max(count, 1), visibleRows))
    }

    @objc private func rowClicked() {
        if rows.indices.contains(table.clickedRow) { onActivate?(table.clickedRow) }
    }
}

/// The panels may not be key: the first click must count
private final class QuickTableView: NSTableView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension QuickListView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: QuickRowCell.reuseID, owner: nil) as? QuickRowCell ?? QuickRowCell()
        cell.configure(rows[row])
        return cell
    }
}

@MainActor
private final class QuickRowCell: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("quickRow")
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let trailing = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseID
        icon.contentTintColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle
        trailing.font = .systemFont(ofSize: 11)
        trailing.textColor = .tertiaryLabelColor
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        let texts = NSStackView(views: [title, subtitle])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 0
        for sub in [icon, texts, trailing] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            texts.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            texts.centerYAnchor.constraint(equalTo: centerYAnchor),
            texts.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -8),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        imageView = icon
        textField = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    func configure(_ row: QuickRow) {
        icon.image = NSImage.officialSymbol(row.symbol, fallback: "circle", accessibility: nil)
        icon.contentTintColor = row.tint ?? .secondaryLabelColor
        title.stringValue = row.title
        subtitle.stringValue = row.subtitle
        subtitle.isHidden = row.subtitle.isEmpty
        trailing.stringValue = row.trailing
        setAccessibilityLabel([row.title, row.subtitle, row.trailing].filter { !$0.isEmpty }.joined(separator: ", "))
    }
}

/// Rounded floating surface shared by the quick panels (`.menu` material, like the stash float bar)
@MainActor
final class QuickPanelSurface: NSPanel {
    var acceptsKey = false
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { acceptsKey }
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    init(width: CGFloat, content: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: QuickListView.rowHeight),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false
        let surface = NSVisualEffectView()
        surface.material = .menu
        surface.state = .active
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 8
        surface.layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(content)
        contentView = surface
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: surface.topAnchor, constant: 8),
            content.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -8),
            content.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 4),
            content.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -4),
        ])
    }

    /// Sizes the panel and centers it over `parent`, a little above the middle. `height` is the content's.
    func present(over parent: NSWindow?, height: CGFloat, makeKey: Bool) {
        var frame = NSRect(x: 0, y: 0, width: self.frame.width, height: height + 16)
        if let parent {
            frame.origin.x = parent.frame.midX - frame.width / 2
            frame.origin.y = parent.frame.minY + parent.frame.height * 0.6 - frame.height / 2
            if !isVisible { parent.addChildWindow(self, ordered: .above) }
        }
        setFrame(frame, display: true)
        if makeKey { makeKeyAndOrderFront(nil) } else { orderFront(nil) }
    }

    func dismiss() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}
