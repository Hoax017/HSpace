import AppKit
import QuickLookUI
import HSpaceContracts
import DirectoryReader
import IconThumb
import FileMetadata

/// Miller column view (M9 ⌘3, QSpace/Finder style): a horizontally scrolling NSStackView of columns,
/// each column = a single-column NSTableView (icon + name, row height 22, column width fixed at 220 in v1).
/// Selecting a directory → expands a child column on the right (truncating all columns to its right); selecting a file → simple preview column at the far right.
/// Navigation link (QSpace semantics): drill-down goes up through onNavigate to change the address bar; showDirectory flows back and uses the
/// path prefix to decide "extend in place along the current chain" or "jump and rebuild the chain".
/// Columns load themselves: each has a local DirectoryReader and loads in a Task, cancelled when the column is destroyed/suspended.
/// The shared model's data source semantics stay untouched (switching back to the list costs nothing), and column loads stop on pane suspend (north star).
@MainActor
final class FileColumnViewController: NSViewController {
    /// Read-only consumer of the shared model's config (includeHidden/sort) and FSEvents link; column content doesn't go through it
    let model: DirectoryViewModel
    weak var coordinator: FileOpsCoordinator?
    var onNavigate: ((URL) -> Void)?
    var onInteract: (() -> Void)?
    var onSelectionChange: (() -> Void)?

    private let hScroll = NSScrollView()
    private let stack = NSStackView()
    private(set) var columns: [ColumnUnit] = []   // setter private; UISelfTest content-level assertions need to read it
    private var preview: PreviewColumnView?
    private var focusedColumnIndex = 0

    /// Suspended state: while set, all column loads are cancelled and showDirectory only records pending (rebuilt on resume)
    private var suspended = false
    private var pendingDirectory: URL?

    var focusTarget: NSView {
        columns.indices.contains(focusedColumnIndex) ? columns[focusedColumnIndex].tableView : view
    }

    /// Status bar counts (focused column semantics: N items / M selected)
    var statusCounts: (items: Int, selected: Int) {
        guard columns.indices.contains(focusedColumnIndex) else { return (0, 0) }
        let col = columns[focusedColumnIndex]
        return (col.items.count, col.selectedItems.count)
    }

    var selectedItems: [FileItem] {
        columns.indices.contains(focusedColumnIndex) ? columns[focusedColumnIndex].selectedItems : []
    }
    var selectedURLs: [URL] { selectedItems.map(\.url) }

    /// UISelfTest (I-32): raw selected row count of the focused column at the view layer (queries tableView directly); verifies a real clear after delete
    var uiTestFocusedRawSelectionCount: Int {
        columns.indices.contains(focusedColumnIndex)
            ? columns[focusedColumnIndex].tableView.selectedRowIndexes.count : 0
    }

    /// UISelfTest (I-32): selects by URL set in the focused column (simulates user multi-select; through the real selection change chain)
    func uiTestSelectInFocusedColumn(_ urls: [URL]) {
        guard columns.indices.contains(focusedColumnIndex) else { return }
        let col = columns[focusedColumnIndex]
        let wanted = Set(urls)
        var idx = IndexSet()
        for (i, item) in col.items.enumerated() where wanted.contains(item.url) { idx.insert(i) }
        col.tableView.selectRowIndexes(idx, byExtendingSelection: false)
    }

    /// UISelfTest (I-32): URLs of the focused column's items (lets tests get real URLs, avoiding symlink path mismatches)
    var uiTestFocusedColumnItemURLs: [URL] {
        columns.indices.contains(focusedColumnIndex) ? columns[focusedColumnIndex].items.map(\.url) : []
    }

    /// Directory of the focused column (destination for paste/new/empty-space right-click)
    var currentDirectory: URL {
        columns.indices.contains(focusedColumnIndex) ? columns[focusedColumnIndex].directory : model.directory
    }

    init(model: DirectoryViewModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        // FSEvents link: active directory content changed → refresh the matching column (columns still loading are left alone, avoiding a double read on navigate)
        model.addOnUpdate { [weak self] in
            guard let self, !self.suspended, self.view.window != nil else { return }
            if let col = self.columns.first(where: { $0.directory.path == self.model.directory.path }),
               !col.isLoading {
                col.reload()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    override func loadView() {
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false

        hScroll.documentView = stack
        hScroll.hasHorizontalScroller = true
        hScroll.hasVerticalScroller = false
        hScroll.autohidesScrollers = true

        // Horizontally scrolling NSStackView: stack pinned to the clip's top/leading + height fills the viewport; the width fill constraint uses .defaultLow.
        // If the width fill were required, the single column's content width (220) would push back through required constraints and defeat the 999 fill edges
        // PaneViewController uses to mount content views → column width collapse (proved by the M23 assertion, 220×…). .defaultLow lets few columns fill
        // without fighting the 999. (Vertical collapse had a separate cause: the fake intrinsic height of ColumnUnit's vertical separator NSBox; see the fix below.)
        let clip = hScroll.contentView
        let fillW = stack.widthAnchor.constraint(greaterThanOrEqualTo: clip.widthAnchor)
        fillW.priority = .defaultLow
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: clip.topAnchor),
            stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            stack.heightAnchor.constraint(equalTo: clip.heightAnchor),
            fillW,
        ])

        let root = NSView()
        hScroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(hScroll)
        NSLayoutConstraint.activate([
            hScroll.topAnchor.constraint(equalTo: root.topAnchor),
            hScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            hScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            hScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        view = root
    }

    // MARK: Suspend/resume (called by PaneViewController on pane/layout switches; north star of zero background power)

    /// Cancels all in-flight column loads and preview thumbnails; later showDirectory calls only record pending
    func suspend() {
        guard !suspended else { return }
        suspended = true
        columns.forEach { $0.cancelLoad() }
        preview?.cancelThumb()
    }

    /// Resumes and aligns to the current directory: refreshes the column chain if on it, otherwise rebuilds
    func wake(at url: URL) {
        suspended = false
        if let pending = pendingDirectory {
            pendingDirectory = nil
            showDirectory(pending)
        } else if columns.contains(where: { $0.directory.path == url.standardizedFileURL.path }) {
            reloadAllColumns()
        } else {
            showDirectory(url)
        }
    }

    // MARK: Column chain management (drill-down along the chain extends in place; a jump rebuilds)

    /// Presents a directory (the single return entry point for pane navigation):
    /// column for this directory exists → truncate to its right; parent on the chain → extend in place; otherwise rebuild the chain
    func showDirectory(_ url: URL) {
        let std = url.standardizedFileURL
        if suspended { pendingDirectory = std; return }
        if let k = columns.firstIndex(where: { $0.directory.path == std.path }) {
            truncateColumns(after: k)
            removePreview()
        } else if let p = columns.firstIndex(where: { $0.directory.path == std.deletingLastPathComponent().path }) {
            truncateColumns(after: p)
            removePreview()
            columns[p].highlight(url: std)   // Programmatically select the chain row (no further drill-down)
            appendColumn(for: std)
        } else {
            rebuild(root: std)
        }
        scrollToTrailing()
        onSelectionChange?()
    }

    /// Refresh after an operation (coordinator reload path): re-reads all columns (one readdir per column; the column count is limited)
    func reloadAllColumns() {
        guard !suspended else { return }
        columns.forEach { $0.reload() }
    }

    /// Redraw only (cut dimming changed)
    /// Redraw only (cut dimming changed).
    /// **Must not use reloadData()**: it clears the selection, and in a "redraw" the rows haven't changed, so neither should the selection
    /// (user report: the selection highlight vanished after ⌘C). Reloading by rows/columns keeps the selection.
    func redraw() {
        for col in columns {
            let tv = col.tableView
            guard tv.numberOfRows > 0, tv.numberOfColumns > 0 else { continue }
            tv.reloadData(forRowIndexes: IndexSet(integersIn: 0..<tv.numberOfRows),
                          columnIndexes: IndexSet(integersIn: 0..<tv.numberOfColumns))
        }
    }

    /// Restores the selection from a URL set (view mode migration): lands on the leaf column, applied after loading
    func select(urls: [URL]) {
        guard let leaf = columns.last else { return }
        leaf.desiredSelection = Set(urls)
        leaf.applyDesiredSelectionIfLoaded()
        view.window?.makeFirstResponder(leaf.tableView)   // I-48: focus the leaf column so the selection shows the blue accent (without first responder the unemphasized gray is nearly invisible)
    }

    /// Takes and clears the leaf column's pending reveal (for relocation on view mode switch; same semantics as FileRevealTarget.takePendingReveal)
    func takePendingReveal() -> URL? {
        guard let leaf = columns.last, let url = leaf.desiredSelection.first else { return nil }
        leaf.desiredSelection = []
        return url
    }

    private func rebuild(root: URL) {
        truncateColumns(after: -1)
        removePreview()
        appendColumn(for: root)
        focusedColumnIndex = 0
    }

    /// Removes all columns after index (-1 = all), cancelling their in-flight loads
    private func truncateColumns(after index: Int) {
        guard index < columns.count - 1 else { return }
        for col in columns[(index + 1)...] {
            col.cancelLoad()
            stack.removeArrangedSubview(col)
            col.removeFromSuperview()
        }
        columns.removeLast(columns.count - index - 1)
        if focusedColumnIndex > index { focusedColumnIndex = max(0, index) }
    }

    private func appendColumn(for directory: URL) {
        let col = ColumnUnit(directory: directory, owner: self)
        columns.append(col)
        stack.addArrangedSubview(col)
        col.heightAnchor.constraint(equalTo: stack.heightAnchor).isActive = true
        col.reload()
    }

    private func removePreview() {
        guard let p = preview else { return }
        p.cancelThumb()
        stack.removeArrangedSubview(p)
        p.removeFromSuperview()
        preview = nil
    }

    private func showPreview(for item: FileItem) {
        removePreview()
        let p = PreviewColumnView()
        preview = p
        stack.addArrangedSubview(p)
        p.heightAnchor.constraint(equalTo: stack.heightAnchor).isActive = true
        p.show(item)
        scrollToTrailing()
    }

    private func scrollToTrailing() {
        view.layoutSubtreeIfNeeded()
        let clip = hScroll.contentView
        let x = max(0, stack.fittingSize.width - clip.bounds.width)
        clip.scroll(to: NSPoint(x: x, y: clip.bounds.origin.y))
        hScroll.reflectScrolledClipView(clip)
    }

    // MARK: Column callbacks (ColumnUnit → semantic decisions live here)

    func columnInteracted(_ column: ColumnUnit) {
        if let i = columns.firstIndex(where: { $0 === column }) { focusedColumnIndex = i }
        onInteract?()
    }

    /// User-level selection change: single directory = drill down (syncing the address bar through the pane); single file = preview column; multi/cleared = truncate right columns
    func selectionChanged(in column: ColumnUnit) {
        guard columns.contains(where: { $0 === column }) else { return }
        let sel = column.selectedItems
        if sel.count == 1, let item = sel.first {
            if item.isDirectory && !item.isPackage {
                onNavigate?(item.url)
            } else {
                onNavigate?(column.directory)
                showPreview(for: item)
            }
        } else {
            onNavigate?(column.directory)
            removePreview()
        }
        onSelectionChange?()
        if QLPreviewPanel.sharedPreviewPanelExists(),
           let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.reloadData()
        }
    }

    func columnContentChanged(_ column: ColumnUnit) {
        onSelectionChange?()   // Refresh counts (the status bar reads statusCounts through the pane)
    }

    func doubleClicked(in column: ColumnUnit) {
        let row = column.tableView.clickedRow
        guard row >= 0, row < column.items.count else { return }
        let item = column.items[row]
        // Directories already drilled down on single click; files/packages open in the system default app
        if !item.isDirectory || item.isPackage {
            coordinator?.recordAccess(item.url)   // M28: opening a file = one usage record
            NSWorkspace.shared.open(item.url)
        }
    }

    /// ←/→ moving between columns: ← focuses the parent column; → focuses the child column (with no selection, selects the first row to trigger drill-down/preview)
    func moveFocus(from column: ColumnUnit, direction: Int) {
        guard let i = columns.firstIndex(where: { $0 === column }) else { return }
        let target = i + direction
        guard columns.indices.contains(target) else { NSSound.beep(); return }
        let t = columns[target]
        focusedColumnIndex = target
        view.window?.makeFirstResponder(t.tableView)
        if direction > 0, t.tableView.selectedRowIndexes.isEmpty, !t.items.isEmpty {
            t.tableView.selectRowIndexes([0], byExtendingSelection: false)
            t.tableView.scrollRowToVisible(0)
        }
        onSelectionChange?()
    }

    func menu(for column: ColumnUnit) -> NSMenu {
        if let i = columns.firstIndex(where: { $0 === column }) { focusedColumnIndex = i }
        return FileContextMenuBuilder.menu(selection: column.selectedItems,
                                           directory: column.directory, target: self)
    }

    func isCut(_ url: URL) -> Bool { coordinator?.isCut(url) ?? false }

    // MARK: Drop semantics (same as the list: directory row = drop into that folder; empty space/file row = drop into the column's directory; ⌥ copies)

    func validateDrop(in column: ColumnUnit, info: any NSDraggingInfo,
                      proposedRow row: Int, operation op: NSTableView.DropOperation) -> NSDragOperation {
        guard let urls = Self.draggedFileURLs(info), !urls.isEmpty else { return [] }
        var targetRow = -1
        if op == .on, row >= 0, row < column.items.count,
           column.items[row].isDirectory, !column.items[row].isPackage {
            targetRow = row
        }
        let target = targetRow >= 0 ? column.items[targetRow].url : column.directory
        guard urls.allSatisfy({ !FileOpsCoordinator.isSelfOrDescendant(destination: target, ofSource: $0) }) else {
            return []
        }
        guard !DropFeedback.refusesTrash(target, in: view.window) else { return [] }
        // Same decision as the submission in dropTransfer (drag preference + ⌥ + volume), so the cursor cannot disagree with it
        let willMove = FileOpsCoordinator.effectiveMove(
            urls: urls, into: target, optionCopy: info.draggingSourceOperationMask == .copy)
        let feedback = DropFeedback.operation(willMove: willMove, urls: urls, target: target)
        guard !feedback.isEmpty else { return [] }
        if targetRow >= 0 {
            column.tableView.setDropRow(targetRow, dropOperation: .on)
        } else {
            column.tableView.setDropRow(-1, dropOperation: .on)   // Whole-column highlight = drop into the column's directory
        }
        return feedback
    }

    func acceptDrop(in column: ColumnUnit, info: any NSDraggingInfo,
                    row: Int, operation op: NSTableView.DropOperation) -> Bool {
        guard let urls = Self.draggedFileURLs(info), !urls.isEmpty else { return false }
        var target = column.directory
        if op == .on, row >= 0, row < column.items.count,
           column.items[row].isDirectory, !column.items[row].isPackage {
            target = column.items[row].url
        }
        coordinator?.dropTransfer(urls: urls, into: target,
                                  forceCopy: info.draggingSourceOperationMask == .copy)
        return true
    }

    private static func draggedFileURLs(_ info: any NSDraggingInfo) -> [URL]? {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL]
    }

    // MARK: Menu commands (responder chain; act on the focused column; rename unimplemented → not responding is honestly grayed out)

    @objc func toggleHiddenFiles(_ sender: Any?) {
        model.includeHidden.toggle()
        reloadAllColumns()
    }

    @objc func refresh(_ sender: Any?) {
        model.reload()
        reloadAllColumns()
    }

    @objc func copyItems(_ sender: Any?) { coordinator?.copy(selectedURLs) }
    @objc func cutItems(_ sender: Any?) { coordinator?.cut(selectedURLs) }
    /// Put Back (only inside the Trash; works only for items in the ledger, others honestly grayed out)
    @objc func putBackItems(_ sender: Any?) { coordinator?.putBack(selectedURLs) }

    @objc func pasteItems(_ sender: Any?) { coordinator?.paste(into: currentDirectory, revealIn: nil) }
    /// Copy Path (⌘⇧C): **with nothing selected, falls back to the current directory**. Pressing the shortcut on empty space in a folder
    /// means "copy the path of the folder I'm in" (Finder's ⌥⌘C on empty space also gives the current folder).
    /// It used to pass only selectedURLs, an empty array with no selection, which copyPaths' guard swallowed, so the shortcut seemed dead.
    @objc func copyPath(_ sender: Any?) { copyPath(to: .general) }

    /// For self-tests to inject a private pasteboard (the product path always uses .general)
    func copyPath(to pasteboard: NSPasteboard) {
        coordinator?.copyPaths(selectedURLs.isEmpty ? [currentDirectory] : selectedURLs, to: pasteboard)
    }
    @objc func copy(_ sender: Any?) { copyItems(sender) }
    @objc func cut(_ sender: Any?) { cutItems(sender) }
    @objc func paste(_ sender: Any?) { pasteItems(sender) }

    @objc func duplicateItems(_ sender: Any?) { coordinator?.duplicate(selectedURLs) }
    @objc func moveToTrash(_ sender: Any?) { coordinator?.moveToTrash(selectedURLs) }
    @objc func newFolderHere(_ sender: Any?) { coordinator?.newFolder(in: currentDirectory, revealIn: nil) }
    @objc func editTags(_ sender: Any?) { coordinator?.metadataActions.editTags(of: selectedItems, host: self) }
    @objc func editComment(_ sender: Any?) { coordinator?.metadataActions.editComment(of: selectedItems) }
    @objc func newFileHere(_ sender: Any?) { coordinator?.newFile(in: currentDirectory, revealIn: nil) }
    @objc func copyToOtherPane(_ sender: Any?) { coordinator?.copyToOtherPane(selectedURLs) }
    @objc func moveToOtherPane(_ sender: Any?) { coordinator?.moveToOtherPane(selectedURLs) }

    @objc func openSelected(_ sender: Any?) {
        for item in selectedItems {
            if item.isDirectory && !item.isPackage {
                onNavigate?(item.url)
            } else {
                coordinator?.recordAccess(item.url)   // M28: opening a file = one usage record
                NSWorkspace.shared.open(item.url)
            }
        }
    }

    @objc func openWithApp(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let app = item.representedObject as? URL else { return }
        NSWorkspace.shared.open(selectedURLs, withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func openWithOther(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let app = panel.url else { return }
        NSWorkspace.shared.open(selectedURLs, withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func getInfo(_ sender: Any?) {
        let target = selectedURLs.first ?? currentDirectory
        InfoPanel.show(for: target)
    }

    @objc func openInTerminal(_ sender: Any?) {
        TerminalResolver.open(selectedItems.first(where: { $0.isDirectory })?.url ?? currentDirectory)
    }

    @objc func showPackageContents(_ sender: Any?) {
        guard let pkg = selectedItems.first(where: { $0.isPackage }) else { return }
        onNavigate?(pkg.url)
    }

    // MARK: Quick Look (space toggles; data source = the focused column's selection)

    /// I-45: dismiss with a fade rather than "shrink to icon" (same as the list view: sourceFrame returns .zero when dismissing)
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
}

extension FileColumnViewController: MetadataMenuHost {
    var metadataModel: DirectoryViewModel { model }

    func metadata(for urls: [URL]) -> [URL: ItemMetadata] {
        columns.first { $0.items.contains { urls.contains($0.url) } }?.metadata ?? [:]
    }
}

// MARK: - Menu validation (enable/disable by the focused column's selection state)

extension FileColumnViewController: @preconcurrency NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let hasSelection = !selectedItems.isEmpty
        switch menuItem.action {
        // Copy Path is always available: with no selection it falls back to the focused column's directory (same as the list view)
        case #selector(copyPath(_:)):
            return true
        case #selector(putBackItems(_:)):
            return TrashLocation.isInsideTrash(currentDirectory) && !selectedURLs.isEmpty
        case #selector(copyItems(_:)), #selector(cutItems(_:)),
             #selector(duplicateItems(_:)), #selector(moveToTrash(_:)), #selector(openSelected(_:)),
             #selector(copyToOtherPane(_:)), #selector(moveToOtherPane(_:)),
             #selector(copy(_:)), #selector(cut(_:)):
            return hasSelection
        // Inside the Trash, disable actions that "bring live files in" (Finder disables them too). These became reachable only once
        // the Trash was browsable: files put here have no undo and no Put Back metadata,
        // so emptying the Trash later would really lose them. Same fix across all three views.
        case #selector(pasteItems(_:)), #selector(paste(_:)):
            if TrashLocation.isInsideTrash(currentDirectory) { return false }
            return NSPasteboard.general.canReadObject(forClasses: [NSURL.self],
                                                      options: [.urlReadingFileURLsOnly: true])
        case #selector(newFolderHere(_:)), #selector(newFileHere(_:)):
            return !TrashLocation.isInsideTrash(currentDirectory)
        default:
            return true
        }
    }
}

// MARK: - Quick Look data source/delegate

extension FileColumnViewController: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        selectedItems.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let urls = selectedURLs
        guard index >= 0, index < urls.count else { return nil }
        return urls[index] as NSURL
    }

    /// Arrow keys on the panel go back to the focused column first (↑↓ advance rows, ←→ move columns)
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, (123...126).contains(Int(event.keyCode)) else { return false }
        (focusTarget as? NSTableView)?.keyDown(with: event)
        return true
    }

    /// Zoom animation origin = the row's icon position in the focused column
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        if quickLookDismissing { return .zero }
        guard let url = (item as? NSURL) as URL?,
              columns.indices.contains(focusedColumnIndex),
              let window = view.window else { return .zero }
        let col = columns[focusedColumnIndex]
        guard let row = col.items.firstIndex(where: { $0.url == url }) else { return .zero }
        let rect = col.tableView.convert(NSRect(x: 4, y: 0, width: 22, height: 22)
            .offsetBy(dx: 0, dy: col.tableView.rect(ofRow: row).minY), to: nil)
        return window.convertToScreen(rect)
    }
}

// MARK: - Single column (width fixed at 220 in v1): loads itself (local DirectoryReader), cancelled on destroy/suspend

@MainActor
final class ColumnUnit: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let directory: URL
    private(set) var items: [FileItem] = []
    private(set) var isLoading = false
    let tableView = FocusReportingTableView()
    private let scroll = NSScrollView()
    private weak var owner: FileColumnViewController?

    /// Column-private reader: columns are temporary views, so a local instance (the shared model stays untouched)
    private let reader = DirectoryReader()
    private var loadTask: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?
    /// Tags of this column's items. Columns load themselves, so they read their own.
    private(set) var metadata: [URL: ItemMetadata] = [:]

    /// Guards against programmatic selection loops (chain row highlight/selection restore must not trigger further drill-down)
    private var isProgrammaticSelection = false
    /// Selection to apply after loading (mode switch migration/chain row highlight)
    var desiredSelection: Set<URL> = []

    init(directory: URL, owner: FileColumnViewController) {
        self.directory = directory
        self.owner = owner
        super.init(frame: .zero)

        tableView.onInteract = { [weak self] in
            guard let self else { return }
            self.owner?.columnInteracted(self)
        }
        tableView.menuProvider = { [weak self] _ in
            guard let self else { return nil }
            return self.owner?.menu(for: self)
        }
        tableView.onReturn = { NSSound.beep() }   // Columns have no inline rename (honest feedback)
        tableView.onSpace = { [weak self] in self?.owner?.toggleQuickLook(nil) }
        tableView.onArrowLeft = { [weak self] in
            guard let self else { return }
            self.owner?.moveFocus(from: self, direction: -1)
        }
        tableView.onArrowRight = { [weak self] in
            guard let self else { return }
            self.owner?.moveFocus(from: self, direction: 1)
        }
        tableView.style = .plain
        tableView.headerView = nil
        tableView.rowHeight = 22
        tableView.usesAutomaticRowHeights = false
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(didDoubleClick(_:))
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        tableView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: false)

        let col = NSTableColumn(identifier: .init("name"))
        col.width = 204
        tableView.addTableColumn(col)

        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        // Vertical separator: an NSBox separator's intrinsic content size defaults to "horizontal line (height=1)", which through the required constraint chain
        // (separator↔ColumnUnit↔stack↔clip↔scrollView↔column root↔contentContainer) collapses the whole column vertically to 1pt
        // (proved by the M23 assertion + a constraint dump: NSContentSizeLayoutConstraint: NSBox.height==1). Lowering its vertical
        // hugging/compression resistance to the minimum lets top/bottom constraints set the height, removing this fake height demand.
        separator.setContentHuggingPriority(.init(1), for: .vertical)
        separator.setContentCompressionResistancePriority(.init(1), for: .vertical)

        addSubview(scroll)
        addSubview(separator)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 220),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: separator.leadingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            // I-24b: the vertical separator must be pinned to width 1: with no width constraint the horizontal ambiguity resolves to "separator 219/scroll area 0",
            // with all content clipped by a zero-width clip layer (exposed after the vertical collapse fix; proved by a layer chain dump: NSClipView 0x393)
            separator.widthAnchor.constraint(equalToConstant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    // MARK: Loading (column-private Task; stops on cancel)

    func reload() {
        loadTask?.cancel()
        isLoading = true
        let request = ReadRequest(directory: directory,
                                  includeHidden: owner?.model.includeHidden ?? false,
                                  sort: owner?.model.sort ?? SortSpec())
        let needsTagsFirst = owner?.model.tagsShapeList ?? false
        loadTask = Task { [weak self, reader] in
            let snap = try? await reader.load(request)
            let loaded = snap?.items ?? []
            // A filter or tag sort cannot show anything before the tags are known
            let tags = needsTagsFirst ? try? await Engines.metadata.read(loaded.map(\.url)) : nil
            guard let self, !Task.isCancelled else { return }
            self.isLoading = false
            // Keep the existing selection before refreshing (re-reads after FSEvents/operations don't lose it)
            if self.desiredSelection.isEmpty {
                self.desiredSelection = Set(self.selectedItems.map(\.url))
            }
            if let tags { self.metadata = tags }
            // Read failed → empty column in place (no alert)
            self.items = self.owner?.model.arranged(
                loaded, metadata: self.metadata,
                applyFilter: self.directory.path == self.owner?.model.directory.path) ?? loaded
            self.isProgrammaticSelection = true
            self.tableView.reloadData()
            self.isProgrammaticSelection = false
            self.applyDesiredSelectionIfLoaded()
            self.owner?.columnContentChanged(self)
            if tags == nil { self.refreshMetadata(for: loaded) }
        }
    }

    /// Reads tags after the column shows, then updates the visible rows in place
    private func refreshMetadata(for items: [FileItem]) {
        metadataTask?.cancel()
        let urls = items.map(\.url)
        metadataTask = Task { [weak self] in
            guard let fresh = try? await Engines.metadata.read(urls), let self, !Task.isCancelled,
                  fresh != self.metadata else { return }
            self.metadata = fresh
            let range = self.tableView.rows(in: self.tableView.visibleRect)
            for row in range.location..<(range.location + range.length) where self.items.indices.contains(row) {
                let cell = self.tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NameCellView
                cell?.decorate(tags: fresh[self.items[row].url]?.tags ?? [])
            }
        }
    }

    func cancelLoad() {
        loadTask?.cancel()
        loadTask = nil
        metadataTask?.cancel()
        metadataTask = nil
        isLoading = false
    }

    // MARK: Selection

    var selectedItems: [FileItem] {
        tableView.selectedRowIndexes.compactMap { items.indices.contains($0) ? items[$0] : nil }
    }

    /// Programmatically highlights the chain row (the parent column keeps the child directory selected after drill-down; no further drill-down)
    func highlight(url: URL) {
        desiredSelection = [url]
        applyDesiredSelectionIfLoaded()
    }

    func applyDesiredSelectionIfLoaded() {
        guard !items.isEmpty else { return }          // Empty column has no rows to select; desiredSelection is kept for a later load
        guard !desiredSelection.isEmpty else { return } // No selection pending restore: leave things as they are
        var indexes = IndexSet()
        // Standardized path compare + case-insensitive fallback (on case-insensitive volumes user-supplied case often differs from disk); same fix as I-39/I-55
        let wantedPaths = Set(desiredSelection.map { $0.standardizedFileURL.path })
        for (i, item) in items.enumerated() {
            let p = item.url.standardizedFileURL.path
            if wantedPaths.contains(p)
                || wantedPaths.contains(where: { $0.compare(p, options: .caseInsensitive) == .orderedSame }) {
                indexes.insert(i)
            }
        }
        // When nothing matched, treat it as "really missing" and consume it only if this column really is the directory of those targets.
        // Otherwise the column still holds stale content from the previous directory; clearing would eat the pending selection, and it would never apply after the right content loads,
        // showing up as nothing selected in column mode after pasting a file path (I-55).
        let ownsTargets = desiredSelection.allSatisfy {
            $0.deletingLastPathComponent().standardizedFileURL.path
                == directory.standardizedFileURL.path
        }
        guard !indexes.isEmpty || ownsTargets else { return }
        desiredSelection = []
        // I-32: restore the exact-match set; even an empty set (all selected items deleted) is selected explicitly to clear,
        // no longer `guard !indexes.isEmpty else { return }`, which left reloadData's row-number leftovers (the real cause of selection "drift" after a delete)
        isProgrammaticSelection = true
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        isProgrammaticSelection = false
        if let first = indexes.first { tableView.scrollRowToVisible(first) }
    }

    // MARK: Table data source/delegate

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let item = items[row]
        let cell = tableView.makeView(withIdentifier: .init("colNameCell"), owner: nil) as? NameCellView
            ?? NameCellView(identifier: .init("colNameCell"))
        let cut = owner?.isCut(item.url) ?? false
        cell.configure(icon: Formatters.icon(for: item), name: item.name,
                       dimmed: item.isHidden || cut)
        cell.decorate(tags: metadata[item.url]?.tags ?? [])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isProgrammaticSelection else { return }
        owner?.selectionChanged(in: self)
    }

    @objc private func didDoubleClick(_ sender: Any?) {
        owner?.doubleClicked(in: self)
    }

    // MARK: Drag source / drop target (semantic decisions live in owner, same as the list)

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard items.indices.contains(row) else { return nil }
        return items[row].url as NSURL
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        owner?.validateDrop(in: self, info: info, proposedRow: row, operation: op) ?? []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo,
                   row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
        owner?.acceptDrop(in: self, info: info, row: row, operation: op) ?? false
    }
}

// MARK: - File preview column (appears at the far right when a file is selected: large image + name + kind/size/date)

@MainActor
final class PreviewColumnView: NSView {
    private let bigIcon = NSImageView()
    private let nameLabel = NSTextField(wrappingLabelWithString: "")
    private let infoLabel = NSTextField(wrappingLabelWithString: "")
    private var thumbTask: Task<Void, Never>?

    init() {
        super.init(frame: .zero)
        bigIcon.imageScaling = .scaleProportionallyUpOrDown

        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.alignment = .center
        nameLabel.maximumNumberOfLines = 3
        nameLabel.lineBreakMode = .byTruncatingMiddle

        infoLabel.font = .systemFont(ofSize: 11)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.alignment = .center
        infoLabel.maximumNumberOfLines = 4

        for sub in [bigIcon, nameLabel, infoLabel] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 220),
            bigIcon.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            bigIcon.centerXAnchor.constraint(equalTo: centerXAnchor),
            bigIcon.widthAnchor.constraint(equalToConstant: 128),
            bigIcon.heightAnchor.constraint(equalToConstant: 128),
            nameLabel.topAnchor.constraint(equalTo: bigIcon.bottomAnchor, constant: 12),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            infoLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 8),
            infoLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            infoLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    func show(_ item: FileItem) {
        cancelThumb()
        bigIcon.image = Formatters.fullIcon(for: item)   // Fast-path type icon first
        nameLabel.stringValue = item.name
        var lines: [String] = [Formatters.kind(forTypeID: item.contentTypeID, isDirectory: item.isDirectory)]
        if let size = item.size {
            lines.append(Formatters.size.string(fromByteCount: size))
        }
        if let modified = item.modified {
            lines.append(Formatters.relativeDate(modified))
        }
        infoLabel.stringValue = lines.joined(separator: "\n")
        // Async upgrade to a large QLThumbnail (keeps the type icon on failure; BG-7: decoration failures don't harm the main chain)
        let url = item.url
        thumbTask = Task { [weak self] in
            let cg = await Engines.iconThumb.thumbnail(for: url, size: 128)
            guard let self, !Task.isCancelled, let cg else { return }
            self.bigIcon.image = NSImage(cgImage: cg, size: NSSize(width: 128, height: 128))
        }
    }

    func cancelThumb() {
        thumbTask?.cancel()
        thumbTask = nil
    }
}
