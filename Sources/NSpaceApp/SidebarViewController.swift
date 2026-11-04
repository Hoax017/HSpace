import AppKit
import NSpaceContracts
import VolumeInfo
import BookmarkStore

/// Left sidebar: source list groups (bookmarks/iCloud/locations, reorderable by dragging header rows).
/// Read-only plus navigation intents (BG-1); bookmark add/remove/change is committed through the BookmarkStore pod.
@MainActor
final class SidebarViewController: NSViewController {
    let model: SidebarModel
    var onNavigate: ((URL) -> Void)?

    /// No navigation during programmatic highlight sync (otherwise selectRowIndexes -> selectionDidChange -> navigate -> sync again, a cycle)
    private var suppressSelectionNavigation = false
    /// Whether the selection really changed during this click.
    /// AppKit order: selection changes during mouseDown tracking -> the action fires on mouseUp.
    /// So if the action sees this flag true, selectionDidChange has already navigated; do not repeat it.
    private var selectionChangedInThisClick = false

    private let stashView = StashShelfView()
    /// Stash shelf area view (UISelfTest I-07 centering measurement entry; M17 §5)
    var stashShelfView: StashShelfView { stashView }
    private let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private let banner = NSTextField(labelWithString: "")
    private var bannerTimer: Timer?
    /// Drag type for reordering bookmarks internally
    private static let reorderType = NSPasteboard.PasteboardType("com.nspace.sidebar.bookmark")
    /// Drag type for reordering group header rows (user request: bookmarks can be dragged to the top)
    private static let groupType = NSPasteboard.PasteboardType("com.nspace.sidebar.group")

    init(model: SidebarModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        model.onChange = { [weak self] in self?.reload() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("main"))
        column.isEditable = false
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.floatsGroupRows = false
        outline.rowSizeStyle = .small  // QSpace-style compact row height
        outline.dataSource = self
        outline.delegate = self
        // Click-driven navigation: clicking the **already selected** row leaves the selection unchanged,
        // so outlineViewSelectionDidChange alone misses it (user report: clicking Downloads does nothing)
        outline.target = self
        outline.action = #selector(rowClicked(_:))
        outline.registerForDraggedTypes([.fileURL, Self.reorderType, Self.groupType])
        outline.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        outline.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: false)
        outline.menu = NSMenu()
        outline.menu?.delegate = self

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        // In-place banner for errors such as eject failure (hides after 3s; modal alerts are forbidden)
        banner.isHidden = true
        banner.font = .systemFont(ofSize: 11)
        banner.textColor = .systemRed
        banner.lineBreakMode = .byTruncatingTail
        banner.maximumNumberOfLines = 2

        let root = NSView()
        let stashSeparator = NSBox()
        stashSeparator.boxType = .separator
        for sub in [stashView, stashSeparator, scroll, banner] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            // QSpace-style flush top: the sidebar runs up to the window top, leaving only the traffic light row height (not anchored to safeArea, not pushed down by a toolbar)
            stashView.topAnchor.constraint(equalTo: root.topAnchor, constant: 36),
            stashView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stashView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stashSeparator.topAnchor.constraint(equalTo: stashView.bottomAnchor),
            stashSeparator.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            stashSeparator.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: stashSeparator.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: banner.topAnchor),
            banner.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            banner.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            banner.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        view = root

        model.start()
    }

    private func reload() {
        // Stash area injection (idempotent; stash is injected later than loadView) + in-place error banner
        if let stash = model.stash {
            stash.onError = { [weak self] message in self?.showBanner(message) }
            stashView.attach(stash)
        }
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
    }

    private func showBanner(_ message: String) {
        banner.stringValue = message
        banner.isHidden = false
        bannerTimer?.invalidate()
        bannerTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.banner.isHidden = true }
        }
    }

    // MARK: Eject

    @objc private func ejectClicked(_ sender: NSButton) {
        let row = outline.row(for: sender)
        guard row >= 0, let leaf = outline.item(atRow: row) as? SidebarLeafNode,
              case let .volume(vol) = leaf.payload else { return }
        do {
            try model.eject(vol)
            Toast.show(L10n.f("toast.ejected", vol.name), in: view.window)
        } catch {
            showBanner(String(format: L10n.t("sidebar.ejectFailed"), vol.name, error.localizedDescription))
        }
    }

    // MARK: Bookmark actions

    @objc private func renameBookmark(_ sender: NSMenuItem) {
        guard let leaf = sender.representedObject as? SidebarLeafNode else { return }
        let row = outline.row(forItem: leaf)
        guard row >= 0,
              let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView,
              let field = cell.textField else { return }
        field.isEditable = true
        field.delegate = self
        outline.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    @objc private func removeBookmark(_ sender: NSMenuItem) {
        guard let leaf = sender.representedObject as? SidebarLeafNode,
              case let .bookmark(item) = leaf.payload else { return }
        Task {
            try? await model.bookmarkStore.remove(item.id)
            model.rebuild()
        }
    }

}

// MARK: - Data source

extension SidebarViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return model.groups.count }
        return (item as? SidebarGroupNode)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return model.groups[index] }
        return (item as! SidebarGroupNode).children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is SidebarGroupNode
    }

    // Drag out: group header = group reorder source; bookmark = reorder source; stash item = resolved real URL (can drop onto any fileURL target)
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        if let group = item as? SidebarGroupNode {
            let pb = NSPasteboardItem()
            pb.setString(group.kind.rawValue, forType: Self.groupType)
            return pb
        }
        guard let leaf = item as? SidebarLeafNode else { return nil }
        guard case .bookmark = leaf.payload,
              let group = model.groups.first(where: { $0.kind == .bookmarks }),
              let index = group.children.firstIndex(where: { $0 === leaf }) else { return nil }
        let pb = NSPasteboardItem()
        pb.setString(String(index), forType: Self.reorderType)
        return pb
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        // Group reorder: groups may only be dragged to the root level (item==nil) between groups (index>=0, not onto the middle of a row)
        if info.draggingPasteboard.types?.contains(Self.groupType) == true {
            if item == nil && index >= 0 { return .move }
            // Hovering over a group/item -> redirect to a root-level gap (drops on the middle are not accepted)
            outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return []
        }
        let isBookmarkGroup = (item as? SidebarGroupNode)?.kind == .bookmarks
        if info.draggingPasteboard.types?.contains(Self.reorderType) == true {
            return isBookmarkGroup && index >= 0 ? .move : []
        }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        guard !urls.isEmpty else { return [] }
        // External files dragged into bookmarks: directories only, with the destination forced to the bookmark group
        guard isBookmarkGroup || item == nil else { return [] }
        let allDirs = urls.allSatisfy {
            var d: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &d) && d.boolValue
        }
        if allDirs {
            outlineView.setDropItem(model.groups.first { $0.kind == .bookmarks }, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .copy
        }
        return []
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        // Group reorder: reorder Preferences.sidebarGroupOrder and rebuild
        if let kindStr = info.draggingPasteboard.string(forType: Self.groupType) {
            reorderGroups(movingKind: kindStr, toVisibleIndex: index)
            return true
        }
        if let str = info.draggingPasteboard.string(forType: Self.reorderType), let from = Int(str) {
            let to = index > from ? index - 1 : index
            Task {
                try? await model.bookmarkStore.move(from: from, to: to)
                model.rebuild()
            }
            return true
        }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        Task {
            for url in urls {
                try? await model.bookmarkStore.add(url)
            }
            model.rebuild()
        }
        return true
    }

    /// Group reorder: recompute the visible group order from the drop point and merge it into the persisted full order (a hidden empty iCloud group goes last without affecting display)
    private func reorderGroups(movingKind kindStr: String, toVisibleIndex index: Int) {
        let visible = model.groups.map { $0.kind.rawValue }
        guard let from = visible.firstIndex(of: kindStr) else { return }
        var newVisible = visible
        let moved = newVisible.remove(at: from)
        let dest = from < index ? index - 1 : index
        newVisible.insert(moved, at: min(max(dest, 0), newVisible.count))
        // Merge into the persisted full order: fill in all three keys -> hidden keys (not in the visible list) go last, visible keys come first in the new order
        var full = Preferences.sidebarGroupOrder
        for key in [SidebarGroupNode.Kind.bookmarks.rawValue,
                    SidebarGroupNode.Kind.icloud.rawValue,
                    SidebarGroupNode.Kind.volumes.rawValue] where !full.contains(key) {
            full.append(key)
        }
        let hidden = full.filter { !newVisible.contains($0) }
        Preferences.sidebarGroupOrder = newVisible + hidden
        model.rebuild()
    }
}

// MARK: - Delegate

extension SidebarViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is SidebarGroupNode
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? SidebarLeafNode)?.url != nil
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? SidebarGroupNode {
            let cell = outlineView.makeView(withIdentifier: .init("group"), owner: nil) as? NSTableCellView
                ?? makeGroupCell()
            cell.textField?.stringValue = group.title
            return cell
        }
        guard let leaf = item as? SidebarLeafNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: .init("leaf"), owner: nil) as? SidebarLeafCell
            ?? SidebarLeafCell(identifier: .init("leaf"))
        var ejectable = false
        if case let .volume(vol) = leaf.payload { ejectable = vol.isEjectable && !vol.isRoot }
        cell.configure(leaf: leaf, ejectable: ejectable,
                       ejectTarget: self, ejectAction: #selector(ejectClicked(_:)))
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        // During programmatic highlight sync, **neither navigate nor leave a "selection changed" trace**:
        // a trace would make the real click right after it get swallowed by handleClick's dedupe,
        // and since the real app syncs on every directory change, the user's "click does nothing" would survive unchanged.
        // (The first version set the flag before the guard; I-68 caught it on the spot.)
        guard !suppressSelectionNavigation else { return }
        selectionChangedInThisClick = true
        navigate(row: outline.selectedRow)
    }

    /// Click-driven navigation: **clicking the already selected row** leaves the selection unchanged,
    /// so `outlineViewSelectionDidChange` never fires; the user's "clicking Downloads does nothing,
    /// I must click something else and come back" is exactly this gap.
    @objc private func rowClicked(_ sender: Any?) {
        handleClick(row: outline.clickedRow)
    }

    /// Click landing point (internal: driven directly by self-tests).
    /// **Do not test this with a synthesized mouseDown**: NSOutlineView's mouseDown starts a mouse tracking loop,
    /// which headless never gets a mouseUp to leave; it hung the entire self-test in practice, starving even
    /// the 180s watchdog on the main thread (a real hang on 2026-09-11).
    func handleClick(row: Int) {
        defer { selectionChangedInThisClick = false }
        guard !selectionChangedInThisClick else { return }   // the selection really changed -> selectionDidChange already navigated
        navigate(row: row)
    }

    private func navigate(row: Int) {
        guard row >= 0,
              let leaf = outline.item(atRow: row) as? SidebarLeafNode,
              let url = leaf.url else { return }
        onNavigate?(url)
    }

    /// Syncs the highlight to the pane's current directory (clears the highlight when no bookmark matches).
    /// The old version **had no such sync at all**: the highlight meant only "what you clicked last", and after changing directory through the breadcrumb/double-click it
    /// kept pointing at the old location: a lie, which also made "click it again" a no-op.
    func syncSelection(to url: URL?) {
        suppressSelectionNavigation = true
        defer { suppressSelectionNavigation = false }
        guard let url else { outline.deselectAll(nil); return }
        let want = url.standardizedFileURL.path
        for row in 0..<outline.numberOfRows {
            if let leaf = outline.item(atRow: row) as? SidebarLeafNode,
               leaf.url?.standardizedFileURL.path == want {
                outline.selectRowIndexes([row], byExtendingSelection: false)
                return
            }
        }
        outline.deselectAll(nil)   // current directory is not bookmarked -> no stale highlight may pose as "you are here"
    }

    // ---- Self-test channel (I-68) ----
    /// URL of the currently highlighted row (nil = no highlight)
    var uiTestSelectedURL: URL? {
        guard outline.selectedRow >= 0,
              let leaf = outline.item(atRow: outline.selectedRow) as? SidebarLeafNode else { return nil }
        return leaf.url
    }
    /// Finds the row number by URL (-1 = not in the sidebar)
    func uiTestRow(for url: URL) -> Int {
        let want = url.standardizedFileURL.path
        for row in 0..<outline.numberOfRows {
            if let leaf = outline.item(atRow: row) as? SidebarLeafNode,
               leaf.url?.standardizedFileURL.path == want { return row }
        }
        return -1
    }
    /// Simulates clicking a row: where the **selection really changes**, uses selectRowIndexes (really fires selectionDidChange),
    /// then adds one handleClick, matching AppKit's actual order (selection changes during mouseDown, the action fires on mouseUp).
    func uiTestClickRow(_ row: Int) {
        guard row >= 0, row < outline.numberOfRows else { return }
        if outline.selectedRow != row { outline.selectRowIndexes([row], byExtendingSelection: false) }
        handleClick(row: row)
    }
    /// Whether click wiring is really attached (the path above uses handleClick, which cannot prove the action is wired)
    var uiTestClickWiredToOutline: Bool {
        outline.action == #selector(rowClicked(_:)) && (outline.target as? SidebarViewController) === self
    }

    private func makeGroupCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = .init("group")
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

// MARK: - Context menu (bookmarks: rename/remove; stash shelf: remove/clear)

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outline.clickedRow
        guard row >= 0 else { return }
        guard let leaf = outline.item(atRow: row) as? SidebarLeafNode,
              case .bookmark = leaf.payload else { return }
        let rename = menu.addItem(withTitle: L10n.t("sidebar.rename"),
                                  action: #selector(renameBookmark(_:)), keyEquivalent: "")
        rename.target = self
        rename.representedObject = leaf
        let remove = menu.addItem(withTitle: L10n.t("sidebar.remove"),
                                  action: #selector(removeBookmark(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = leaf
    }
}

// MARK: - Bookmark inline rename commit

extension SidebarViewController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        field.isEditable = false
        let row = outline.row(for: field)
        guard row >= 0, let leaf = outline.item(atRow: row) as? SidebarLeafNode,
              case let .bookmark(item) = leaf.payload else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty, newName != item.name else {
            field.stringValue = item.name  // FG-6: invalid input rolls back to the old name
            return
        }
        Task {
            try? await model.bookmarkStore.rename(item.id, to: newName)
            model.rebuild()
        }
    }
}

/// Sidebar leaf row: icon + title (+ capacity subtitle) (+ eject button)
@MainActor
final class SidebarLeafCell: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let eject = NSButton()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 10)
        subtitle.textColor = .tertiaryLabelColor
        eject.image = NSImage(systemSymbolName: "eject.fill", accessibilityDescription: L10n.t("sidebar.eject"))
        eject.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        eject.isBordered = false
        eject.contentTintColor = .secondaryLabelColor
        eject.toolTip = L10n.t("sidebar.eject")
        for sub in [icon, title, subtitle, eject] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.trailingAnchor.constraint(lessThanOrEqualTo: eject.leadingAnchor, constant: -4),
            title.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -1),
            subtitle.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: eject.leadingAnchor, constant: -4),
            subtitle.centerYAnchor.constraint(equalTo: centerYAnchor),
            eject.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            eject.centerYAnchor.constraint(equalTo: centerYAnchor),
            eject.widthAnchor.constraint(equalToConstant: 20),
        ])
        imageView = icon
        textField = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    func configure(leaf: SidebarLeafNode, ejectable: Bool, ejectTarget: AnyObject, ejectAction: Selector) {
        icon.image = leaf.icon
        icon.contentTintColor = leaf.tint  // Finder-style blue favorites (nil = original color)
        title.stringValue = leaf.title
        // Title color: explicit override first (stash action rows/lost items); otherwise gray for a lost target
        title.textColor = leaf.titleColor ?? (leaf.url == nil ? .tertiaryLabelColor : .labelColor)
        subtitle.stringValue = leaf.subtitle ?? ""
        subtitle.isHidden = leaf.subtitle == nil
        eject.isHidden = !ejectable
        eject.target = ejectTarget
        eject.action = ejectAction
    }
}
