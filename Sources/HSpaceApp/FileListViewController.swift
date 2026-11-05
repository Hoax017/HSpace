import AppKit
import QuickLookUI
import UniformTypeIdentifiers
import HSpaceContracts
import ArchiveEngine
import FolderSize
import IconThumb
import FileMetadata

/// List view (the performance core): view-based NSTableView, fixed row height, row reuse, sortable columns.
/// Read-only consumer of DirectoryViewModel (BG-1: no write-type file APIs in this layer);
/// all file change intents go through FileOpsCoordinator, which builds an OperationSpec for the kernel.
/// Async decoration chains (FolderSize/IconThumb) fire only for visible rows and cancel on scroll-out: the north star of zero waste.
@MainActor
final class FileListViewController: NSViewController, FileRevealTarget {
    let model: DirectoryViewModel
    /// File-operation bridge (injected by the pane)
    weak var coordinator: FileOpsCoordinator?
    /// Navigation intent, passed up (history coordinated by the pane)
    var onNavigate: ((URL) -> Void)?
    /// Go-back intent, passed up (when Backspace=back; the pane uses browser history)
    var onNavigateBack: (() -> Void)?
    /// User interaction, passed up (pane focus coordination)
    var onInteract: (() -> Void)?
    /// Selection change, passed up (status bar "M selected")
    var onSelectionChange: (() -> Void)?
    /// Passed up after a snapshot is applied (status bar "N items")
    var onContentChange: (() -> Void)?

    let tableView = FocusReportingTableView()   // internal: UISelfTest I-26 column header sort assertions need to drive sortDescriptors
    private let scrollView = BlankAreaScrollView()
    /// Blank height always kept at the bottom of the list (4pt scale), reserved for right-clicks on empty space
    static let blankTailHeight: CGFloat = 40
    private let emptyLabel = NSTextField(labelWithString: "")

    /// Target to reveal (select / enter rename) after an operation completes
    private var pendingReveal: (url: URL, rename: Bool)?

    /// Selected URL cache (I-32): updated live on each selection change. By applySnapshot time model.items is already new,
    /// and looking up the current selectedRowIndexes would map old row numbers onto shifted items (the real cause of selection "drifting" to the top row after a delete).
    /// So this cache is the source of truth: after reloadData, restore by exact URL match; deleted items have no match and are explicitly cleared.
    private var selectionURLCache: Set<URL> = []

    /// spring-loaded state: the folder row under a drag hover + the trigger timer
    private var springLoad: (row: Int, timer: Timer)?

    // MARK: Grouping (M26): the single source of truth for row ↔ item mapping

    /// Display row sequence (grouping on = [header, items...] interleaved; off = one row per item).
    /// Never scatter index arithmetic elsewhere: all row→item and item→row conversions go through this array's helpers.
    private enum ListRow {
        case group(key: String, title: String, count: Int)
        case item(Int)   // Index into model.items
    }
    private var listRows: [ListRow] = []
    /// Set of collapsed group keys (used on regroup to decide whether to expand a group's items)
    // Collapsing was dropped (owner request: group headers are printed on a background strip, not expandable controls).
    // No always-empty set is kept: that would leave a half-implementation that "looks collapsible but isn't".
    /// Group filter: when non-nil only that group shows ("Show Only This Group"); nil = all groups
    private var groupFilterKey: String?
    /// Filter-state pill (FG-1: no mystery while filtered, one click restores)
    private let filterPill = FilterPillButton()

    // Decoration state (derived display layer, disposable at any time): backfilled directory sizes / upgraded thumbnails / in-flight requests
    private var sizeOverlay: [URL: Int64] = [:]
    private var thumbOverlay: [URL: NSImage] = [:]
    private var sizeTasks: [URL: Task<Void, Never>] = [:]
    private var thumbTasks: [URL: Task<Void, Never>] = [:]
    /// Thumbnail eligibility cached per UTType (no repeated conforms work on the scroll path)
    private static var thumbEligible: [String: Bool] = [:]

    /// Keyboard focus target (PaneGrid calls makeFirstResponder on this view when activating)
    var focusTarget: NSView { tableView }

    /// Current directory (destination for new items, paste and open in terminal)
    var currentDirectory: URL { model.directory }

    init(model: DirectoryViewModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        model.addOnUpdate { [weak self] in self?.applySnapshot() }
        model.addOnError { [weak self] message in self?.showEmptyState(message) }
        model.addOnMetadataChange { [weak self] in self?.showMetadataChange() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    override func loadView() {
        tableView.onInteract = { [weak self] in self?.onInteract?() }
        tableView.menuProvider = { [weak self] row in self?.buildMenu(clickedRow: row) }
        tableView.onReturn = { [weak self] in self?.beginRenameSelected() }
        // Click on a selected item → rename (user report: only Enter could trigger it). The predicate and delay live in the table view;
        // this only wires the result. No renaming inside the Trash (it would only rename the Trash copy, which is pointless)
        tableView.onSingleClickRename = { [weak self] row in
            guard let self, !TrashLocation.isInsideTrash(self.currentDirectory) else { return }
            self.beginRename(row: row)
        }
        tableView.onOpenSelected = { [weak self] in self?.openSelected(nil) }
        tableView.onBackspaceAction = { [weak self] in self?.handleBackspace() }
        tableView.onSpace = { [weak self] in self?.toggleQuickLook(nil) }
        tableView.onDragExited = { [weak self] in self?.cancelSpringLoad() }
        tableView.isGroupRowProvider = { [weak self] row in self?.isGroupRow(row) ?? false }
        tableView.style = .plain  // Compact density: remove the large inset margins (QSpace style)
        tableView.intercellSpacing = NSSize(width: 8, height: 0)
        tableView.rowHeight = Self.rowHeight(for: Formatters.listFontSize)
        tableView.usesAutomaticRowHeights = false
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.floatsGroupRows = true   // M26: floating group headers
        // Name column flexes to take the remaining width, the others stay narrow and fixed (QSpace/Finder semantics), so narrow panes keep all four columns
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(didDoubleClick(_:))
        // Drag: out to Finder/other apps/another pane/sidebar/stash shelf; in accepts fileURL
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        tableView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: false)

        addColumn(id: "name", title: L10n.t("column.name"), width: 280, min: 110, sortable: true)
        rebuildOptionalColumns()
        // Column header right-click: QSpace-style optional column toggles
        let headerMenu = NSMenu()
        headerMenu.delegate = self
        tableView.headerView?.menu = headerMenu

        scrollView.documentView = tableView
        // Always keep a right-clickable blank area at the bottom (user report: when content fills the view, "there's no blank area left, I have nowhere to click").
        // Uses contentInsets rather than fake rows: the table's data source stays clean, and this area falls on the clip view,
        // where BlankAreaScrollView.menu(for:) shows the directory-level menu.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: Self.blankTailHeight, right: 0)
        scrollView.onBlankMenu = { [weak self] in self?.buildMenu(clickedRow: -1) }
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        // Scroll/size change → recompute decoration requests for visible rows (requests only for visible rows, cancelled on scroll-out)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        // Column visibility / list font size broadcast: rebuild optional columns (including reloadData) and sync row height to the font; takes effect at once
        NotificationCenter.default.addObserver(
            self, selector: #selector(columnsOrFontChanged(_:)),
            name: .hspaceColumnsChanged, object: nil)
        // Grouping toggle broadcast: regroup rows, takes effect at once
        NotificationCenter.default.addObserver(
            self, selector: #selector(groupingChanged(_:)),
            name: .hspaceGroupingChanged, object: nil)

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(scrollView)
        root.addSubview(emptyLabel)
        // Filter-state pill (FG-1): floats at the top right of the list (near the column header); hidden normally, shown when filtered, click to restore
        filterPill.isHidden = true
        filterPill.target = self
        filterPill.action = #selector(filterPillClicked(_:))
        filterPill.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(filterPill)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 20),
            filterPill.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
            filterPill.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            filterPill.heightAnchor.constraint(equalToConstant: 20),
        ])
        view = root
        syncSortIndicatorFromModel()   // I-58: attach the indicator on first load (new panes no longer show "Name")
        model.reload()
    }

    /// Optional column registry (Name is always present; I-26: every column header sorts on click, ids map one-to-one to SortSpec.Key raw values)
    static let optionalColumns: [(id: String, titleKey: String, width: CGFloat, min: CGFloat, right: Bool, sortable: Bool)] = [
        ("dateModified", "column.dateModified", 128, 88, false, true),
        ("created", "column.created", 128, 88, false, true),
        ("added", "column.added", 128, 88, false, true),
        ("size", "column.size", 68, 52, true, true),
        ("kind", "column.kind", 92, 64, false, true),
        ("tags", "column.tags", 92, 64, false, true),
        ("comment", "column.comment", 128, 64, false, false),
    ]

    private func addColumn(id: String, title: String, width: CGFloat, min: CGFloat,
                           rightAlign: Bool = false, sortable: Bool = false) {
        let col = NSTableColumn(identifier: .init(id))
        col.title = title
        col.width = width
        col.minWidth = min
        col.resizingMask = [.userResizingMask, .autoresizingMask]
        if sortable { col.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true) }
        if rightAlign { col.headerCell.alignment = .right }
        tableView.addTableColumn(col)
    }

    /// Rebuilds optional columns from preferences (called when column header toggles change)
    private func rebuildOptionalColumns() {
        for col in tableView.tableColumns where col.identifier.rawValue != "name" {
            tableView.removeTableColumn(col)
        }
        let visible = Preferences.visibleColumns
        for c in Self.optionalColumns where visible.contains(c.id) {
            addColumn(id: c.id, title: L10n.t(c.titleKey), width: c.width, min: c.min,
                      rightAlign: c.right, sortable: c.sortable)
        }
        syncSortIndicatorFromModel()   // I-58: removing and re-adding columns loses the indicator, so reattach it
        tableView.reloadData()
    }

    /// Row height follows font size (larger fonts get taller rows to avoid clipping): 24 at >=13, otherwise 22
    private static func rowHeight(for fontSize: CGFloat) -> CGFloat {
        fontSize >= 13 ? 24 : 22
    }

    /// Handles the column visibility/font size broadcast: rebuilds columns (reloadData makes cells re-read the font) + syncs row height
    @objc private func columnsOrFontChanged(_ note: Notification) {
        tableView.rowHeight = Self.rowHeight(for: Formatters.listFontSize)
        rebuildOptionalColumns()
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var visible = Preferences.visibleColumns
        if let i = visible.firstIndex(of: id) { visible.remove(at: i) } else { visible.append(id) }
        Preferences.visibleColumns = visible
        // Broadcast: all pane lists rebuild in sync (simplification: this pane is immediate, others would match by their next snapshot;
        // viewFor renders by the current columns, so just notify everyone)
        NotificationCenter.default.post(name: .hspaceColumnsChanged, object: nil)
    }

    private var lastSnapshotDirectory: URL?

    private func applySnapshot() {
        // Directory switch: cancel all in-flight decoration requests and clear backfilled results (URLs aren't reused across directories)
        if lastSnapshotDirectory != model.directory {
            lastSnapshotDirectory = model.directory
            cancelDecorationWork()
            sizeOverlay.removeAll()
        }
        // Same-directory refreshes clear the thumbnail overlay too: file contents may have changed (the IconThumb cache key includes mtime, so a refetch either hits or regenerates)
        thumbOverlay.removeAll()
        emptyLabel.isHidden = true
        syncSortIndicatorFromModel()   // I-58: column header arrow follows model.sort (no longer stuck on "Name" after restore/directory change)
        // FSEvents auto-refresh must never swallow the user's selection: record URLs before reloadData, restore by URL after (including multi-selection).
        // I-32: the selection source of truth is selectionURLCache (updated on selection change, reflecting the actual pre-delete selection),
        // not the current selectedURLs: model.items is already new, and old row numbers would map onto shifted items and "drift".
        let selectedBefore = selectionURLCache
        rebuildListRows()          // M26: rebuild the row sequence (grouped: [header, items...]; otherwise one row per item)
        tableView.reloadData()
        var rows = IndexSet()
        for url in selectedBefore {
            if let r = row(forURL: url) { rows.insert(r) }
        }
        // Restore the exact-match set; even an empty set (say all selected items were deleted) is selected explicitly to clear, never leaving reloadData's row-number leftovers
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        if model.items.isEmpty, !model.isLoading {
            showEmptyState(L10n.t("empty.folder"))
        }
        revealPendingIfPossible()
        refreshVisibleDecorations()
        onContentChange?()
    }

    private func showEmptyState(_ message: String) {
        emptyLabel.stringValue = message
        emptyLabel.isHidden = false
    }

    /// Tags arrived or changed: updates visible rows in place, never the name editor. Rows scrolled in later read them in viewFor.
    private func showMetadataChange() {
        let range = tableView.rows(in: tableView.visibleRect)
        var rows = IndexSet()
        for row in range.location..<(range.location + range.length) {
            guard let item = item(atRow: row) else { continue }
            rows.insert(row)
            let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NameCellView
            cell?.decorate(FileDecoration(item, model.metadata[item.url]))
        }
        var columns = IndexSet()
        for (index, column) in tableView.tableColumns.enumerated()
        where Self.metadataColumnIDs.contains(column.identifier.rawValue) { columns.insert(index) }
        if !rows.isEmpty, !columns.isEmpty { tableView.reloadData(forRowIndexes: rows, columnIndexes: columns) }
    }

    private static let metadataColumnIDs: Set<String> = ["tags", "comment"]
    /// The Tags column sorts through the model's tag sort, because tags are not part of `SortSpec`
    private static let tagSortKey = "tags"

    /// Redraw only (called by the coordinator when cut dimming changes)
    /// Redraw only (cut dimming changed).
    /// **Must not use reloadData()**: it clears the selection, and in a "redraw" the rows haven't changed, so neither should the selection
    /// (user report: the selection highlight vanished after ⌘C). Reloading by rows/columns keeps the selection.
    func redraw() {
        guard tableView.numberOfRows > 0, tableView.numberOfColumns > 0 else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: 0..<tableView.numberOfRows),
                             columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
    }

    // MARK: Grouping conversions (M26): group keys/bucketing are delegated to FileGrouping (source of truth shared by list and icon views); this layer handles only display row order and view state

    /// Grouping is active when the preference is on and the current sort key is date-like
    private var groupingActive: Bool {
        FileGrouping.active(model)
    }

    static func isDateKey(_ k: SortSpec.Key) -> Bool { FileGrouping.isDateKey(k) }

    /// Rebuilds the display row sequence from the current model.items (already sorted by the reader).
    /// Group order = first appearance among the sorted items (the sort direction naturally sets group order); items keep their relative order inside a group.
    private func rebuildListRows() {
        listRows.removeAll(keepingCapacity: true)
        guard groupingActive else {
            for i in model.items.indices { listRows.append(.item(i)) }
            filterPill.isHidden = true
            return
        }
        let groups = FileGrouping.groups(for: model)
        var titles: [String: String] = [:]
        for g in groups { titles[g.key] = g.title }
        // Filter self-heal: the filtered group no longer exists (directory/sort key changed) → clear the filter
        if let only = groupFilterKey, !groups.contains(where: { $0.key == only }) { groupFilterKey = nil }
        for g in groups where groupFilterKey == nil || groupFilterKey == g.key {
            listRows.append(.group(key: g.key, title: g.title, count: g.indices.count))
            for i in g.indices { listRows.append(.item(i)) }
        }
        updateFilterPill(titles: titles)
    }

    private func updateFilterPill(titles: [String: String]) {
        if let only = groupFilterKey {
            filterPill.title = L10n.f("group.filter.pill", titles[only] ?? only)
            filterPill.isHidden = false
        } else {
            filterPill.isHidden = true
        }
    }

    /// Row → model.items index (group header/out of bounds → nil)
    func itemIndex(forRow row: Int) -> Int? {
        guard listRows.indices.contains(row) else { return nil }
        if case .item(let i) = listRows[row] { return i }
        return nil
    }

    /// Row → FileItem (group header/out of bounds → nil)
    func item(atRow row: Int) -> FileItem? {
        guard let i = itemIndex(forRow: row), model.items.indices.contains(i) else { return nil }
        return model.items[i]
    }

    /// model.items index → row (item in a collapsed group → nil)
    func row(forItemIndex idx: Int) -> Int? {
        for (r, lr) in listRows.enumerated() {
            if case .item(let i) = lr, i == idx { return r }
        }
        return nil
    }

    /// URL → row (not loaded/in a collapsed group → nil)
    func row(forURL url: URL) -> Int? {
        // Standardized path compare + case-insensitive fallback, unified in model.itemIndex(forURL:) (I-39/I-55)
        guard let idx = model.itemIndex(forURL: url) else { return nil }
        return row(forItemIndex: idx)
    }

    /// Whether this row is a group header
    func isGroupRow(_ row: Int) -> Bool {
        guard listRows.indices.contains(row) else { return false }
        if case .group = listRows[row] { return true }
        return false
    }

    /// Applies a group filter ("Show Only This Group")
    func applyGroupFilter(key: String) {
        groupFilterKey = key
        rebuildRowsPreservingSelection()
    }

    /// Clears the group filter ("Show All Groups" / pill click)
    func clearGroupFilter() {
        groupFilterKey = nil
        rebuildRowsPreservingSelection()
    }

    @objc private func filterPillClicked(_ sender: Any?) { clearGroupFilter() }

    /// Regroups without a model reload: rebuilds rows, calls reloadData, restores the selection exactly from selectionURLCache
    private func rebuildRowsPreservingSelection() {
        let selectedBefore = selectionURLCache
        rebuildListRows()
        tableView.reloadData()
        var rows = IndexSet()
        for url in selectedBefore {
            if let r = row(forURL: url) { rows.insert(r) }
        }
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        refreshVisibleDecorations()
    }

    /// Grouping toggle broadcast: regrouping takes effect at once (all list panes)
    @objc private func groupingChanged(_ note: Notification) {
        rebuildRowsPreservingSelection()
    }


    // MARK: On-demand decoration (FolderSize directory sizes + IconThumb thumbnails, visible rows only, cancelled on scroll-out)

    @objc private func scrollBoundsChanged(_ note: Notification) {
        refreshVisibleDecorations()
    }

    /// Cancels all in-flight decoration requests (called on tab/pane suspend and directory switch; backfilled results are kept)
    func cancelDecorationWork() {
        sizeTasks.values.forEach { $0.cancel() }
        sizeTasks.removeAll()
        thumbTasks.values.forEach { $0.cancel() }
        thumbTasks.removeAll()
    }

    /// Issues missing decoration requests for visible rows; cancels all in-flight requests no longer visible
    func refreshVisibleDecorations() {
        guard view.window != nil, !model.items.isEmpty else { return }
        let range = tableView.rows(in: tableView.visibleRect)
        var wantedSizes = Set<URL>()
        var wantedThumbs = Set<URL>()
        if range.length > 0 {
            for row in range.location..<(range.location + range.length) {
                guard let item = item(atRow: row) else { continue }   // Skip group headers
                if item.isDirectory, item.size == nil, sizeOverlay[item.url] == nil {
                    wantedSizes.insert(item.url)
                    requestFolderSize(item.url)
                }
                if thumbOverlay[item.url] == nil, wantsThumbnail(item) {
                    wantedThumbs.insert(item.url)
                    requestThumbnail(item.url)
                }
            }
        }
        for (url, task) in sizeTasks where !wantedSizes.contains(url) {
            task.cancel(); sizeTasks[url] = nil
        }
        for (url, task) in thumbTasks where !wantedThumbs.contains(url) {
            task.cancel(); thumbTasks[url] = nil
        }
    }

    /// Types worth a content thumbnail: images/audio-video/PDF; directories and app bundles use existing icons (no QuickLook request)
    private func wantsThumbnail(_ item: FileItem) -> Bool {
        guard !item.isDirectory, !item.isPackage, let id = item.contentTypeID else { return false }
        if let cached = Self.thumbEligible[id] { return cached }
        let type = UTType(id)
        let ok = type?.conforms(to: .image) == true
            || type?.conforms(to: .audiovisualContent) == true
            || type?.conforms(to: .pdf) == true
        Self.thumbEligible[id] = ok
        return ok
    }

    private func requestFolderSize(_ url: URL) {
        guard sizeTasks[url] == nil else { return }
        sizeTasks[url] = Task { [weak self] in
            let size = try? await Engines.folderSize.size(of: url)
            guard let self, !Task.isCancelled else { return }
            self.sizeTasks[url] = nil
            guard let size else { return }
            self.sizeOverlay[url] = size
            // Refresh this row's size column only if it still represents the same URL
            guard let row = self.row(forURL: url) else { return }
            let col = self.tableView.column(withIdentifier: .init("size"))
            guard col >= 0 else { return }
            self.tableView.reloadData(forRowIndexes: [row], columnIndexes: [col])
        }
    }

    private func requestThumbnail(_ url: URL) {
        guard thumbTasks[url] == nil else { return }
        thumbTasks[url] = Task { [weak self] in
            let cg = await Engines.iconThumb.thumbnail(for: url, size: 32)
            guard let self, !Task.isCancelled else { return }
            self.thumbTasks[url] = nil
            guard let cg else { return }
            let image = NSImage(cgImage: cg, size: NSSize(width: 16, height: 16))
            self.thumbOverlay[url] = image
            // Swap the image directly without reloading the row, to avoid interrupting an inline rename in progress
            guard let row = self.row(forURL: url),
                  let cell = self.tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                    as? NameCellView else { return }
            cell.imageView?.image = image
        }
    }

    // MARK: Selection state

    var selectedItems: [FileItem] {
        tableView.selectedRowIndexes.compactMap { item(atRow: $0) }
    }
    var selectedURLs: [URL] { selectedItems.map(\.url) }

    /// Restores the selection from a URL set (used to carry selection across view mode switches); matches standardized paths (trailing-slash differences across sources, I-39)
    func select(urls: [URL]) {
        let wanted = Set(urls.map { $0.standardizedFileURL.path })
        var indexes = IndexSet()
        for (i, item) in model.items.enumerated()
        where wanted.contains(item.url.standardizedFileURL.path) {
            if let r = row(forItemIndex: i) { indexes.insert(r) }
        }
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        if let first = indexes.first { tableView.scrollRowToVisible(first) }
    }

    // MARK: Reveal (select and enter rename after creating)

    func prepareReveal(_ url: URL, rename: Bool) { pendingReveal = (url, rename) }

    func takePendingReveal() -> (url: URL, rename: Bool)? {
        defer { pendingReveal = nil }
        return pendingReveal
    }

    /// UISelfTest (I-55): whether a pending reveal is still set; verifies a missed pending target is voided on the spot
    /// and not left as a time bomb that later "ghost-selects" and steals keyboard focus
    var uiTestHasPendingReveal: Bool { pendingReveal != nil }

    private func revealPendingIfPossible() {
        guard let pending = pendingReveal else { return }
        guard let row = row(forURL: pending.url) else {
            // The target's directory has loaded yet the target still isn't found (filtered as hidden / deleted / name mismatch):
            // void it on the spot. Otherwise the pending target stays set until some later refresh or entering a directory that happens
            // to have an item of that name, where it suddenly "ghost-selects" and steals keyboard focus too.
            if model.isLoadedDirectory(forParentOf: pending.url) { pendingReveal = nil }
            return
        }
        pendingReveal = nil
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        // I-48: focus the table after revealing so the selection shows the blue accent highlight; otherwise, without first responder, it shows
        // only an unemphasized gray (nearly invisible in dark mode), and users report "it opened but no blue selection" (especially for browser/external reveals landing in a new window).
        if !pending.rename { view.window?.makeFirstResponder(tableView) }
        if pending.rename { beginRename(row: row) }
    }

    // MARK: Open behaviour (spec feature 9: files open in the system default app; folders navigate within the pane)

    @objc private func didDoubleClick(_ sender: Any?) {
        let row = tableView.clickedRow
        // Double-clicking empty space (clickedRow<0): go to the parent folder, per usage preference
        if row < 0 {
            if Preferences.doubleClickBlank { goUp() }
            return
        }
        guard let item = item(atRow: row) else { return }   // Double-clicking a group header does nothing
        open(item)
    }

    func open(_ item: FileItem) {
        if item.isDirectory && !item.isPackage {
            onNavigate?(item.url)
        } else {
            coordinator?.recordAccess(item.url)   // M28: opening a file = one usage record
            NSWorkspace.shared.open(item.url)
        }
    }

    /// Goes to the parent folder (shared by double-click on empty space / Backspace=up; no-op at the root)
    private func goUp() {
        let parent = currentDirectory.deletingLastPathComponent().standardizedFileURL
        guard parent.path != currentDirectory.standardizedFileURL.path else { return }
        onNavigate?(parent)
    }

    /// Backspace key dispatch (usage preference: ignore/back/move to Trash/up)
    private func handleBackspace() {
        switch Preferences.backspaceAction {
        case "back": onNavigateBack?()
        case "delete": coordinator?.moveToTrash(selectedURLs)
        case "up": goUp()
        default: break  // ignore: don't intercept
        }
    }

    // MARK: Context menu

    private func buildMenu(clickedRow row: Int) -> NSMenu {
        // Right-click on a group header: group filter menu (Show Only This Group / Show All Groups)
        if isGroupRow(row), case .group(let key, _, _) = listRows[row] {
            return buildGroupMenu(key: key)
        }
        return FileContextMenuBuilder.menu(selection: selectedItems, directory: currentDirectory, target: self)
    }

    /// Group header context menu (FG-3: Show Only This Group / Show All Groups)
    private func buildGroupMenu(key: String) -> NSMenu {
        let menu = NSMenu()
        let only = menu.addItem(withTitle: L10n.t("group.filter.only"),
                                action: #selector(groupFilterOnly(_:)), keyEquivalent: "")
        only.target = self
        only.representedObject = key
        let all = menu.addItem(withTitle: L10n.t("group.filter.all"),
                               action: #selector(groupFilterAll(_:)), keyEquivalent: "")
        all.target = self
        all.isEnabled = (groupFilterKey != nil)
        return menu
    }

    @objc private func groupFilterOnly(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        applyGroupFilter(key: key)
    }

    @objc private func groupFilterAll(_ sender: Any?) { clearGroupFilter() }

    // MARK: Inline rename (FG-6: on failure, atomically roll back the old name + beep + red text in place for 2s)

    private func beginRenameSelected() {
        let rows = tableView.selectedRowIndexes
        guard rows.count == 1, let row = rows.first else { NSSound.beep(); return }
        beginRename(row: row)
    }

    func beginRename(row: Int) {
        guard let item = item(atRow: row),
              let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NameCellView
        else { return }
        cell.onRenameCommit = { [weak self] newName in self?.submitRename(item, newName: newName, row: row) }
        cell.onRenameCancel = { }
        cell.beginRename()
    }

    private func submitRename(_ item: FileItem, newName: String, row: Int) {
        coordinator?.rename(item.url, to: newName) { [weak self] ok in
            if !ok { self?.flashRenameError(row: row) }
            // Success: the coordinator already reloaded; failure: no reload, the label still shows the old name (atomic rollback)
        }
    }

    /// FG-6 in-place error: beep + red text on the row for 2s, no page jump or blank screen
    private func flashRenameError(row: Int) {
        NSSound.beep()
        guard item(atRow: row) != nil else { return }
        let rect = tableView.rect(ofRow: row)
        let banner = NSTextField(labelWithString: L10n.t("rename.failed"))
        banner.textColor = .systemRed
        banner.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.9)
        banner.drawsBackground = true
        banner.font = .systemFont(ofSize: 11)
        banner.frame = NSRect(x: rect.minX + 24, y: rect.minY + 2, width: 240, height: 20)
        tableView.addSubview(banner)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            banner.removeFromSuperview()
        }
    }

    // MARK: Menu commands (responder chain)

    @objc func toggleHiddenFiles(_ sender: Any?) { model.includeHidden.toggle() }
    @objc func refresh(_ sender: Any?) { model.reload() }

    /// Use Groups toggle (View menu): flips the preference and broadcasts; all list panes regroup at once
    @objc func toggleGrouping(_ sender: Any?) {
        Preferences.listGrouping.toggle()
        NotificationCenter.default.post(name: .hspaceGroupingChanged, object: nil)
    }

    // Copy/Cut/Paste/Copy Path (shared by the Edit menu ⌘C/⌘X/⌘V/⌘⇧C and the context menu)
    @objc func copyItems(_ sender: Any?) { coordinator?.copy(selectedURLs) }
    @objc func cutItems(_ sender: Any?) { coordinator?.cut(selectedURLs) }
    /// Put Back (only inside the Trash; works only for items in the ledger, others honestly grayed out)
    @objc func putBackItems(_ sender: Any?) { coordinator?.putBack(selectedURLs) }

    // ---- Self-test channel (I-65) ----
    /// Bottom inset of the real scrollView (doesn't copy the constant: this only goes red if the constant changes without the wiring)
    var uiTestBottomInset: CGFloat { scrollView.contentInsets.bottom }
    /// Goes through the callback actually injected into BlankAreaScrollView (not buildMenu directly, or broken wiring would go undetected)
    func uiTestBlankAreaMenu() -> NSMenu? { scrollView.onBlankMenu?() }

    @objc func pasteItems(_ sender: Any?) { coordinator?.paste(into: currentDirectory, revealIn: self) }
    /// Copy Path (⌘⇧C): **with nothing selected, falls back to the current directory**. Pressing the shortcut on empty space in a folder
    /// means "copy the path of the folder I'm in" (Finder's ⌥⌘C on empty space also gives the current folder).
    /// It used to pass only selectedURLs, an empty array with no selection, which copyPaths' guard swallowed, so the shortcut seemed dead.
    @objc func copyPath(_ sender: Any?) { copyPath(to: .general) }

    /// For self-tests to inject a private pasteboard (the product path always uses .general)
    func copyPath(to pasteboard: NSPasteboard) {
        coordinator?.copyPaths(selectedURLs.isEmpty ? [currentDirectory] : selectedURLs, to: pasteboard)
    }
    // NSText standard selector forwarding (⌘C/⌘X/⌘V work when the table view is first responder)
    @objc func copy(_ sender: Any?) { copyItems(sender) }
    @objc func cut(_ sender: Any?) { cutItems(sender) }
    @objc func paste(_ sender: Any?) { pasteItems(sender) }

    @objc func duplicateItems(_ sender: Any?) { coordinator?.duplicate(selectedURLs) }
    @objc func moveToTrash(_ sender: Any?) { coordinator?.moveToTrash(selectedURLs) }

    // Archives: compress any selection; extract supported archives (into=nil same directory / choose directory)
    @objc func compressItems(_ sender: Any?) { coordinator?.compress(selectedURLs) }
    @objc func extractItems(_ sender: Any?) { coordinator?.extract(selectedArchiveURLs, into: nil) }
    @objc func extractItemsTo(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.t("menu.extractTo.prompt")
        panel.directoryURL = currentDirectory
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        coordinator?.extract(selectedArchiveURLs, into: dir)
    }

    /// Extractable archive URLs in the selection (context menu "Extract" filters on this)
    private var selectedArchiveURLs: [URL] {
        selectedItems.filter { ArchiveEngineNode.isSupportedArchive($0.url) }.map(\.url)
    }
    @objc func newFolderHere(_ sender: Any?) { coordinator?.newFolder(in: currentDirectory, revealIn: self) }
    @objc func newFileHere(_ sender: Any?) { coordinator?.newFile(in: currentDirectory, revealIn: self) }
    @objc func renameSelected(_ sender: Any?) { beginRenameSelected() }
    @objc func editTags(_ sender: Any?) { coordinator?.metadataActions.editTags(of: selectedItems, host: self) }
    @objc func editComment(_ sender: Any?) { coordinator?.metadataActions.editComment(of: selectedItems) }
    @objc func editFolderIcon(_ sender: Any?) { coordinator?.metadataActions.editFolderIcon(of: selectedItems) }
    @objc func copyToOtherPane(_ sender: Any?) { coordinator?.copyToOtherPane(selectedURLs) }
    @objc func moveToOtherPane(_ sender: Any?) { coordinator?.moveToOtherPane(selectedURLs) }

    @objc func openSelected(_ sender: Any?) { selectedItems.forEach { open($0) } }

    @objc func openWithApp(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let app = item.representedObject as? URL else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(selectedURLs, withApplicationAt: app, configuration: cfg)
    }

    @objc func openWithOther(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let app = panel.url else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(selectedURLs, withApplicationAt: app, configuration: cfg)
    }

    /// AirDrop the selection (toolbar icon entry; failure beeps, no alert)
    @objc func airdropSelected(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty,
              let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: urls) else { NSSound.beep(); return }
        service.perform(withItems: urls)
    }

    @objc func getInfo(_ sender: Any?) {
        let target = selectedURLs.first ?? currentDirectory
        InfoPanel.show(for: target)
    }

    @objc func openInTerminal(_ sender: Any?) {
        // Enter the selected folder if any, otherwise use the current directory
        let dir: URL = selectedItems.first(where: { $0.isDirectory })?.url ?? currentDirectory
        let ws = NSWorkspace.shared
        // Terminal choice comes from settings (auto = prefer iTerm, fall back to Terminal)
        let choice = Preferences.terminalChoice
        let terminal: URL? = choice == "auto"
            ? (ws.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2")
               ?? ws.urlForApplication(withBundleIdentifier: "com.apple.Terminal"))
            : ws.urlForApplication(withBundleIdentifier: choice)
        guard let terminal else { NSSound.beep(); return }
        ws.open([dir], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Quick Look (space toggles; arrow keys preview continuously via selectionDidChange)

    /// I-45: dismiss with a fade rather than "shrink to icon" (users found the zoom abrupt): set before dismissing so sourceFrame returns .zero
    /// and QL fades (just disappears); reset on opening to keep the zoom-from-icon entry. QL re-queries sourceFrame when closing.
    private var quickLookDismissing = false

    @objc func toggleQuickLook(_ sender: Any?) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            quickLookDismissing = true
            panel.orderOut(nil)
        } else if !selectedItems.isEmpty {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        quickLookDismissing = false
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    @objc func showPackageContents(_ sender: Any?) {
        guard let pkg = selectedItems.first(where: { $0.isPackage }) else { return }
        onNavigate?(pkg.url)
    }

    /// UITEST only (I-45): verifies sourceFrame degrades to .zero when dismissing (→ fade/disappear),
    /// and is the row's icon rect when open (→ zoom from icon). The QL panel animation can't be asserted headless, so this only checks the branch logic.
    func uiTestQLSourceFrame(dismissing: Bool, for url: URL) -> NSRect {
        quickLookDismissing = dismissing
        let r = previewPanel(nil, sourceFrameOnScreenFor: url as NSURL)
        quickLookDismissing = false
        return r
    }
}

extension FileListViewController: MetadataMenuHost {
    var metadataModel: DirectoryViewModel { model }
    func metadata(for urls: [URL]) -> [URL: ItemMetadata] { model.metadata }
}

// MARK: - Menu validation (enable/disable by selection state)

extension FileListViewController: @preconcurrency NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let hasSelection = !tableView.selectedRowIndexes.isEmpty
        let single = tableView.selectedRowIndexes.count == 1
        switch menuItem.action {
        // Copy Path is always available: with no selection it falls back to the current directory (in the hasSelection group the item would be disabled,
        // killing ⌘⇧C on empty space too, which is exactly what users reported)
        case #selector(copyPath(_:)):
            return true
        case #selector(putBackItems(_:)):
            return TrashLocation.isInsideTrash(currentDirectory) && !selectedURLs.isEmpty
        // A duplicate in the Trash = one more file that can only be emptied, so disable it
        case #selector(duplicateItems(_:)) where TrashLocation.isInsideTrash(currentDirectory):
            return false
        case #selector(copyItems(_:)), #selector(cutItems(_:)),
             #selector(duplicateItems(_:)), #selector(moveToTrash(_:)), #selector(openSelected(_:)),
             #selector(copyToOtherPane(_:)), #selector(moveToOtherPane(_:)),
             #selector(copy(_:)), #selector(cut(_:)), #selector(airdropSelected(_:)),
             #selector(compressItems(_:)), #selector(editTags(_:)), #selector(editComment(_:)):
            return hasSelection
        case #selector(editFolderIcon(_:)):
            return selectedItems.contains(where: MetadataActions.isFolder)
        case #selector(extractItems(_:)), #selector(extractItemsTo(_:)):
            return !selectedArchiveURLs.isEmpty
        case #selector(renameSelected(_:)):
            return single
        case #selector(toggleGrouping(_:)):
            menuItem.state = Preferences.listGrouping ? .on : .off
            return true
        // Inside the Trash, disable actions that "bring live files in" (Finder disables them too). These became reachable only once
        // the Trash was browsable: files put here have no undo and no Put Back metadata,
        // so emptying the Trash later would really lose them.
        case #selector(pasteItems(_:)), #selector(paste(_:)):
            return TrashLocation.isInsideTrash(currentDirectory) ? false : pasteboardHasFiles
        case #selector(newFolderHere(_:)), #selector(newFileHere(_:)):
            return !TrashLocation.isInsideTrash(currentDirectory)
        default:
            return true
        }
    }

    private var pasteboardHasFiles: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSURL.self],
                                           options: [.urlReadingFileURLsOnly: true])
    }
}

// MARK: - Column header context menu (optional column toggles, QSpace style)

extension FileListViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let visible = Preferences.visibleColumns
        for c in Self.optionalColumns {
            let item = menu.addItem(withTitle: L10n.t(c.titleKey),
                                    action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = c.id
            item.state = visible.contains(c.id) ? .on : .off
        }
        menu.addItem(.separator())
        let reset = menu.addItem(withTitle: L10n.t("column.reset"),
                                 action: #selector(resetColumns(_:)), keyEquivalent: "")
        reset.target = self
    }

    @objc private func resetColumns(_ sender: Any?) {
        Preferences.visibleColumns = ["dateModified", "size", "kind"]
        NotificationCenter.default.post(name: .hspaceColumnsChanged, object: nil)
    }
}

extension Notification.Name {
    static let hspaceColumnsChanged = Notification.Name("hspaceColumnsChanged")
    /// Grouping toggle changed (View menu "Use Groups" / settings): all list panes rebuild row order at once
    static let hspaceGroupingChanged = Notification.Name("hspaceGroupingChanged")
}

// MARK: - Data source / delegate

extension FileListViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        listRows.count
    }

    // MARK: Group row mechanics (M26): isGroupRow + headers unselectable + header row height 24

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        isGroupRow(row)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !isGroupRow(row)
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        isGroupRow(row) ? 24 : Self.rowHeight(for: Formatters.listFontSize)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        // Group header row: full-width header view (built once for the first column, nil for the others)
        if isGroupRow(row) {
            guard tableColumn == nil || tableColumn == tableView.tableColumns.first else { return nil }
            guard case .group(_, let title, let count) = listRows[row] else { return nil }
            let cell = tableView.makeView(withIdentifier: .init("groupHeader"), owner: nil) as? GroupHeaderView
                ?? GroupHeaderView(identifier: .init("groupHeader"))
            cell.configure(title: title, count: count)
            return cell
        }
        guard let colID = tableColumn?.identifier.rawValue, let item = item(atRow: row) else { return nil }

        if colID == "name" {
            let cell = tableView.makeView(withIdentifier: .init("nameCell"), owner: nil) as? NameCellView
                ?? NameCellView(identifier: .init("nameCell"))
            let cut = coordinator?.isCut(item.url) ?? false
            // Fast path shows the type icon first; a delivered content thumbnail is used directly (upgrade path in requestThumbnail)
            cell.configure(icon: thumbOverlay[item.url] ?? Formatters.icon(for: item),
                           name: item.name, dimmed: item.isHidden || cut)
            cell.decorate(FileDecoration(item, model.metadata[item.url]))
            return cell
        }

        let cell = tableView.makeView(withIdentifier: .init("textCell"), owner: nil) as? TextCellView
            ?? TextCellView(identifier: .init("textCell"))
        switch colID {
        case "dateModified":
            cell.configure(item.modified.map { Formatters.relativeDate($0) } ?? "—", alignment: .left, monospacedDigits: true)
        case "created":
            cell.configure(item.created.map { Formatters.relativeDate($0) } ?? "—", alignment: .left, monospacedDigits: true)
        case "added":
            cell.configure(item.added.map { Formatters.relativeDate($0) } ?? "—", alignment: .left, monospacedDigits: true)
        case "size":
            // Files use the snapshot byte count; directories are nil in the snapshot → backfilled FolderSize result, otherwise placeholder "—"
            if let bytes = item.size ?? sizeOverlay[item.url] {
                let parts = Formatters.sizeParts(fromByteCount: bytes)
                cell.configureSize(value: parts.value, unit: parts.unit, alignment: .right)
            } else {
                cell.configure("—", alignment: .right, monospacedDigits: true)
            }
        case "kind":
            cell.configure(Formatters.kind(forTypeID: item.contentTypeID, isDirectory: item.isDirectory), alignment: .left)
        case "tags":
            cell.configure((model.metadata[item.url]?.tags ?? []).map(\.name).joined(separator: ", "), alignment: .left)
        case "comment":
            cell.configure(model.metadata[item.url]?.comment ?? "", alignment: .left)
        default:
            cell.configure("", alignment: .left)
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = tableView.sortDescriptors.first, let key = d.key else { return }
        if key == Self.tagSortKey {
            model.setTagSort(ascending: d.ascending)
            return
        }
        guard let sortKey = SortSpec.Key(rawValue: key) else { return }
        model.setTagSort(ascending: nil)
        model.sort = SortSpec(key: sortKey, ascending: d.ascending, foldersFirst: model.sort.foldersFirst)
        // I-50: persist on sort change (otherwise sorting saves only on a clean exit, and an unclean exit restarts with the old sort); same as I-47 persist-on-navigate
        (NSApp.delegate as? AppDelegate)?.noteStateChanged()
    }

    /// Syncs model.sort back to the column header indicator (I-58).
    /// The data flow used to be **one-way**: only "user clicks header → sortDescriptorsDidChange → model.sort",
    /// with no way back. So after session restore, new panes/tabs or rebuilding optional columns, data sorted correctly by model.sort
    /// while the column header arrow stayed on the default "Name", and users saw "the sort state was lost".
    /// Column ids map one-to-one to SortSpec.Key.rawValue (addColumn builds sortDescriptorPrototype from the same id).
    private func syncSortIndicatorFromModel() {
        let wanted = model.tagSortAscending.map { NSSortDescriptor(key: Self.tagSortKey, ascending: $0) }
            ?? NSSortDescriptor(key: model.sort.key.rawValue, ascending: model.sort.ascending)
        let current = tableView.sortDescriptors.first
        // Skip the assignment if already consistent: it calls back sortDescriptorsDidChange and triggers a needless save
        guard current?.key != wanted.key || current?.ascending != wanted.ascending else { return }
        tableView.sortDescriptors = [wanted]
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // I-32: selection source-of-truth bookkeeping (user clicks and programmatic selects both come here; reloadData itself doesn't, so the cache keeps the pre-delete value)
        selectionURLCache = Set(selectedURLs)
        onSelectionChange?()
        if QLPreviewPanel.sharedPreviewPanelExists(),
           let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.reloadData()
        }
    }

    // MARK: Drag source (can drag to Finder/other apps/another pane/sidebar bookmarks/stash shelf)

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        // I-43: AppKit calls this only when a drag starts; sets the flag so mouseDown can tell "drag" from "plain click on a selected row"
        (tableView as? FocusReportingTableView)?.dragInitiated = true
        guard let item = item(atRow: row) else { return nil }   // Group headers can't be dragged
        return item.url as NSURL
    }

    // MARK: Drop target (BG-1: the destination only sends intent; kind decision and submission live in the coordinator)

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard let urls = Self.draggedFileURLs(info), !urls.isEmpty else {
            cancelSpringLoad(); return []
        }
        // Normalize the destination: directory row = drop into that folder; file row/header/empty space = drop into the current directory
        var targetRow = -1
        if op == .on, let it = item(atRow: row), it.isDirectory, !it.isPackage {
            targetRow = row
        }
        let target = targetRow >= 0 ? (item(atRow: targetRow)?.url ?? currentDirectory) : currentDirectory
        // Refuse dropping a directory into itself/a descendant
        guard urls.allSatisfy({ !FileOpsCoordinator.isSelfOrDescendant(destination: target, ofSource: $0) }) else {
            cancelSpringLoad(); return []
        }
        guard !DropFeedback.refusesTrash(target, in: view.window) else { cancelSpringLoad(); return [] }
        // With ⌥ held, AppKit has already filtered the source mask to .copy
        let optionCopy = info.draggingSourceOperationMask == .copy
        // Move or copy at the destination: decided uniformly from the drag preference + ⌥ (visual feedback and the actual submission share the logic)
        let willMove = FileOpsCoordinator.effectiveMove(urls: urls, into: target, optionCopy: optionCopy)
        // A move into the same directory is a no-op → refuse (copy is allowed, meaning make a duplicate)
        let destPath = target.standardizedFileURL.path
        if willMove, urls.allSatisfy({ $0.standardizedFileURL.deletingLastPathComponent().path == destPath }) {
            cancelSpringLoad(); return []
        }
        if targetRow >= 0 {
            tableView.setDropRow(targetRow, dropOperation: .on)
            scheduleSpringLoad(row: targetRow, url: target)
        } else {
            tableView.setDropRow(-1, dropOperation: .on)  // Whole-table highlight = drop into the current directory
            cancelSpringLoad()
        }
        // Cursor feedback matches the actual submission (same-volume move / cross-volume copy / preference override)
        return willMove ? .move : .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo,
                   row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
        cancelSpringLoad()
        guard let urls = Self.draggedFileURLs(info), !urls.isEmpty else { return false }
        var target = currentDirectory
        if op == .on, let it = item(atRow: row), it.isDirectory, !it.isPackage {
            target = it.url
        }
        coordinator?.dropTransfer(urls: urls, into: target,
                                  forceCopy: info.draggingSourceOperationMask == .copy)
        return true
    }

    private static func draggedFileURLs(_ info: any NSDraggingInfo) -> [URL]? {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL]
    }

    // MARK: spring-loaded: hovering a drag over a folder row for ~0.8s navigates into it (timer-based, simple and reliable first)

    private func scheduleSpringLoad(row: Int, url: URL) {
        guard springLoad?.row != row else { return }
        cancelSpringLoad()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.cancelSpringLoad()
                self.onNavigate?(url)
            }
        }
        springLoad = (row, timer)
    }

    func cancelSpringLoad() {
        springLoad?.timer.invalidate()
        springLoad = nil
    }
}

// MARK: - Quick Look data source/delegate (multi-selection preview; arrow paging inside the panel is handled by QL)

extension FileListViewController: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        selectedItems.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let urls = selectedURLs
        guard index >= 0, index < urls.count else { return nil }
        return urls[index] as NSURL
    }

    /// Key events on the panel go back to the table first (the panel handles space-to-close itself; arrows fall back to the list to advance the selection)
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, event.keyCode == 125 || event.keyCode == 126 else { return false }
        focusTarget.keyDown(with: event)
        return true
    }

    /// Zoom animation origin = the row's icon position (Finder feel); returns .zero when dismissing → QL fades (I-45: no more shrink to icon)
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        if quickLookDismissing { return .zero }
        guard let url = (item as? NSURL) as URL?,
              let row = row(forURL: url),
              let window = view.window else { return .zero }
        let rect = focusTarget.convert(NSRect(x: 4, y: 0, width: 22, height: 22)
            .offsetBy(dx: 0, dy: (focusTarget as! NSTableView).rect(ofRow: row).minY), to: nil)
        return window.convertToScreen(rect)
    }
}

// MARK: - Filter-state pill (FG-1: 10% pill, restrained style, re-resolved for light/dark)

@MainActor
final class FilterPillButton: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isBordered = false
        bezelStyle = .inline
        font = .systemFont(ofSize: 11)
        contentTintColor = .secondaryLabelColor
        imagePosition = .imageRight
        imageHugsTitle = true
        image = NSImage.officialSymbol("xmark.circle.fill", accessibility: L10n.t("group.filter.all"))
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let base = NSColor.controlBackgroundColor
            let bg = base.blended(withFraction: 0.10, of: Theme.accent) ?? base   // 10% pill
            layer?.backgroundColor = bg.cgColor
            layer?.cornerRadius = 8
        }
    }
}

// MARK: - UISelfTest probes (M26: read-only assertion hooks, not a product path)

extension FileListViewController {
    /// Number of group headers (for grouping assertions)
    var uiTestGroupHeaderCount: Int {
        listRows.reduce(0) { if case .group = $1 { return $0 + 1 }; return $0 }
    }
    /// Group header titles (in row order)
    var uiTestGroupTitles: [String] {
        listRows.compactMap { if case .group(_, let t, _) = $0 { return t }; return nil }
    }
    /// Group header (title, item count) pairs (in row order). Collapsing was dropped, so there's no third element any more.
    var uiTestGroups: [(title: String, count: Int)] {
        listRows.compactMap {
            if case .group(_, let t, let c) = $0 { return (t, c) }
            return nil
        }
    }
    /// Group keys (stable keys, in row order)
    var uiTestGroupKeys: [String] {
        listRows.compactMap { if case .group(let k, _, _) = $0 { return k }; return nil }
    }
    /// Total number of displayed rows
    var uiTestRowCount: Int { listRows.count }
    /// Number of item rows (non-header)
    var uiTestItemRowCount: Int {
        listRows.reduce(0) { if case .item = $1 { return $0 + 1 }; return $0 }
    }
    /// Whether the filter-state pill is visible
    var uiTestFilterPillVisible: Bool { !filterPill.isHidden }
    /// Whether grouping is active (preference on + date sort key)
    var uiTestGroupingActive: Bool { groupingActive }
    /// Clicks a group header through the table view's **real** mouseDown branch (doesn't copy the decision: this goes red only if the wiring breaks)
    func uiTestClickGroupRowRaw(_ row: Int) {
        let rect = tableView.rect(ofRow: row)
        guard let win = view.window,
              let ev = NSEvent.mouseEvent(with: .leftMouseDown,
                                          location: tableView.convert(NSPoint(x: rect.midX, y: rect.midY),
                                                                      to: nil),
                                          modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: win.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: 1) else { return }
        tableView.mouseDown(with: ev)
    }
    /// Selects the first item row (headers are unselectable, so they must be skipped)
    /// Selects by URL set (through the real selection change chain)
    func uiTestSelect(urls: [URL]) {
        let wanted = Set(urls.map(\.standardizedFileURL.path))
        var idx = IndexSet()
        for (r, lr) in listRows.enumerated() {
            guard case .item(let i) = lr, model.items.indices.contains(i) else { continue }
            if wanted.contains(model.items[i].url.standardizedFileURL.path) { idx.insert(r) }
        }
        tableView.selectRowIndexes(idx, byExtendingSelection: false)
    }
    /// **Raw** selected row count at the view layer (queries tableView directly, bypassing any cache;
    /// problems like reloadData clearing the selection are visible only by querying directly)
    var uiTestRawSelectionCount: Int { tableView.selectedRowIndexes.count }

    func uiTestSelectFirstItem() {
        guard let r = uiTestFirstItemRow else { return }
        tableView.selectRowIndexes([r], byExtendingSelection: false)
    }
    /// The header cell really has a background ("printed on a background strip" is what this verifies, not just that nothing crashed)
    var uiTestGroupHeaderIsBackgroundBar: Bool {
        guard let r = listRows.firstIndex(where: { if case .group = $0 { return true }; return false }),
              let cell = tableView.view(atColumn: 0, row: r, makeIfNecessary: true) as? GroupHeaderView,
              let bg = cell.layer?.backgroundColor else { return false }
        return bg.alpha > 0.01
    }

    /// Table row of the first non-header (item) row
    var uiTestFirstItemRow: Int? {
        for (r, lr) in listRows.enumerated() { if case .item = lr { return r } }
        return nil
    }
}
