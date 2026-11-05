import AppKit
import QuickLookUI
import UniformTypeIdentifiers
import HSpaceContracts
import IconThumb

/// Icon grid collection view that reports interaction: a click requests activation of the owning pane; context menu hook;
/// space for Quick Look, double click to open; Return doesn't support rename (an honest beep, no pretending)
@MainActor
final class IconGridCollectionView: NSCollectionView {
    var onInteract: (() -> Void)?
    /// Context menu provider: the argument is the clicked item (nil means empty space, using the directory-level menu)
    var menuProvider: ((IndexPath?) -> NSMenu?)?
    var onSpace: (() -> Void)?
    var onDoubleClick: ((IndexPath) -> Void)?

    override func mouseDown(with event: NSEvent) {
        onInteract?()
        super.mouseDown(with: event)
        // Double click: selection was handled by super; dispatch open
        if event.clickCount == 2 {
            let point = convert(event.locationInWindow, from: nil)
            if let ip = indexPathForItem(at: point) { onDoubleClick?(ip) }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
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
        let ip = indexPathForItem(at: point)
        // Right-clicking an unselected item → make it the only selection first (Finder semantics)
        if let ip, !selectionIndexPaths.contains(ip) {
            deselectAll(nil)
            selectItems(at: [ip], scrollPosition: [])
        }
        return menuProvider?(ip)
    }

    override func keyDown(with event: NSEvent) {
        // Plain ⌘↑/⌘↓ reaching the grid = navigation menu not wired (disabled state): swallow it, so default selection jumps can't replace navigation semantics (I-39);
        // combos with ⇧/⌥/⌃ aren't swallowed and keep system behaviour
        if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
           event.keyCode == 125 || event.keyCode == 126 { return }
        // Space (49) Quick Look; Return (36/76): the icon view has no inline rename, so an honest beep
        if event.keyCode == 49, let onSpace {
            onSpace()
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            NSSound.beep()
            return
        }
        super.keyDown(with: event)
    }
}

/// Icon grid cell: icon (size follows the slider) + two-line truncated file name + rounded selection background
@MainActor
final class FileIconItem: NSCollectionViewItem {
    static let reuseID = NSUserInterfaceItemIdentifier("fileIconItem")

    private let backdrop = NSView()
    private let icon = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")

    override func loadView() {
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 6
        backdrop.translatesAutoresizingMaskIntoConstraints = false

        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: 11)
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let root = NSView()
        root.addSubview(backdrop)
        root.addSubview(icon)
        root.addSubview(label)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: root.topAnchor, constant: 2),
            backdrop.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -2),
            backdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 2),
            backdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -2),
            // Icon area: 16 side padding makes a square (itemSize = icon side + 32)
            icon.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
            icon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            icon.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            icon.heightAnchor.constraint(equalTo: icon.widthAnchor),
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            label.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -4),
        ])
        view = root
        imageView = icon
        textField = label
    }

    override var isSelected: Bool { didSet { updateSelection() } }
    override var highlightState: NSCollectionViewItem.HighlightState { didSet { updateSelection() } }

    private func updateSelection() {
        let active = isSelected || highlightState == .forSelection
        backdrop.layer?.backgroundColor = active
            ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.30).cgColor
            : NSColor.clear.cgColor
    }

    func configure(icon image: NSImage, name: String, dimmed: Bool) {
        icon.image = image
        icon.alphaValue = dimmed ? 0.5 : 1.0
        label.stringValue = name
        label.textColor = dimmed ? .secondaryLabelColor : .labelColor
    }

    /// Thumbnail arrived: swap the image without rebuilding (keeps selection state)
    func setIcon(_ image: NSImage) {
        icon.image = image
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        icon.image = nil
        icon.alphaValue = 1.0
        label.stringValue = ""
    }
}

/// Icon grid view (M9 ⌘1): NSCollectionView + FlowLayout, icons adjustable 48~128 (slider, app-level preference).
/// Shares one DirectoryViewModel with the list (onUpdate multicast); this layer only consumes reads (BG-1: no write-type file APIs);
/// thumbnails are requested async for visible items only and cancelled on scroll-out/suspend (north star of zero waste); semantics match the list:
/// double-click opens, context menu reuses the builder, drag-out/drop use the same volume rules, space for Quick Look.
/// Inline rename isn't supported in this phase (the menu item is honestly grayed out, no faking).
@MainActor
final class FileIconGridViewController: NSViewController, FileRevealTarget {
    let model: DirectoryViewModel
    weak var coordinator: FileOpsCoordinator?
    var onNavigate: ((URL) -> Void)?
    var onInteract: (() -> Void)?
    var onSelectionChange: (() -> Void)?
    var onContentChange: (() -> Void)?

    private let collectionView = IconGridCollectionView()
    private let flowLayout = NSCollectionViewFlowLayout()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let sizeSlider = NSSlider()

    /// Target to reveal (select) after an operation completes; the icon view has no inline rename, so the rename flag is ignored
    private var pendingReveal: (url: URL, rename: Bool)?

    /// Selected URL cache (I-32): updated on selection change, the source of truth for restoring selection in applySnapshot.
    /// Looking up selectionIndexPaths directly would mis-map (model.items is already new), making the selection "drift" to the top item after a delete.
    private var selectionURLCache: Set<URL> = []

    // Grouped view state (M26 v2): the single source of truth for section ↔ model index mapping; never scatter index arithmetic elsewhere.
    // Ungrouped it's one full section (identity mapping); grouped it's one section per group.
    private var sections: [FileGrouping.Group] = []
    // Collapsing was dropped (owner request: group headers are printed on a background strip, not expandable controls).
    // Keeping an always-empty set would leave a half-implementation that "looks collapsible but isn't", so the whole thing was removed.
    private var groupFilterKey: String?
    private let filterPill = FilterPillButton(frame: .zero)

    // Decoration state (derived display layer, disposable at any time)
    private var thumbOverlay: [URL: NSImage] = [:]
    private var thumbTasks: [URL: Task<Void, Never>] = [:]
    /// Thumbnail eligibility cached per UTType (no repeated conforms work on the scroll path)
    private static var thumbEligible: [String: Bool] = [:]

    /// Icon size (app-level preference shared by all pane grids; aligned to the latest value on appear)
    static var preferredIconSize: CGFloat {
        get {
            let v = UserDefaults.standard.double(forKey: "iconGridSize")
            return (48...128).contains(v) ? CGFloat(v) : 80
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: "iconGridSize") }
    }
    private var iconSize: CGFloat = FileIconGridViewController.preferredIconSize

    var focusTarget: NSView { collectionView }

    /// Current directory (destination of empty-space Copy Path / New / Paste; same semantics as the list view)
    var currentDirectory: URL { model.directory }

    init(model: DirectoryViewModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        model.addOnUpdate { [weak self] in self?.applySnapshot() }
        model.addOnError { [weak self] message in self?.showEmptyState(message) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    override func loadView() {
        flowLayout.minimumInteritemSpacing = 8
        flowLayout.minimumLineSpacing = 8
        flowLayout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        flowLayout.sectionHeadersPinToVisibleBounds = true   // M26 v2: floating group headers (matches the list's floatsGroupRows)

        collectionView.collectionViewLayout = flowLayout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(FileIconItem.self, forItemWithIdentifier: FileIconItem.reuseID)
        collectionView.register(IconGroupHeaderView.self,
                                forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                                withIdentifier: IconGroupHeaderView.reuseID)
        collectionView.onInteract = { [weak self] in self?.onInteract?() }
        collectionView.menuProvider = { [weak self] _ in self?.buildMenu() }
        collectionView.onSpace = { [weak self] in self?.toggleQuickLook(nil) }
        collectionView.onDoubleClick = { [weak self] ip in
            guard let self, let file = self.fileItem(at: ip) else { return }
            self.open(file)
        }
        // Drag: same semantics as the list (drag out NSURL; drop on a directory item or empty space = current directory, ⌥ copies)
        collectionView.registerForDraggedTypes([.fileURL])
        collectionView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        collectionView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: false)

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        // Scroll/size change → recompute thumbnail requests for visible items (requests only for visible items, cancelled on scroll-out)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        // Grouping toggle broadcast: rebuild sections, takes effect at once (shares the notification with the list)
        NotificationCenter.default.addObserver(
            self, selector: #selector(groupingChanged(_:)),
            name: Notification.Name.hspaceGroupingChanged, object: nil)

        // Bottom bar: icon size slider (4pt grid: height 24, right edge 8)
        let separator = NSBox()
        separator.boxType = .separator
        let bottomBar = NSView()
        sizeSlider.minValue = 48
        sizeSlider.maxValue = 128
        sizeSlider.doubleValue = Double(iconSize)
        sizeSlider.isContinuous = true
        sizeSlider.controlSize = .small
        sizeSlider.target = self
        sizeSlider.action = #selector(sliderChanged(_:))
        sizeSlider.toolTip = L10n.t("iconGrid.sizeTooltip")
        filterPill.target = self
        filterPill.action = #selector(clearGroupFilter(_:))
        filterPill.isHidden = true
        for sub in [separator, sizeSlider, filterPill] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            bottomBar.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: bottomBar.topAnchor),
            separator.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor),
            sizeSlider.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -8),
            sizeSlider.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            sizeSlider.widthAnchor.constraint(equalToConstant: 120),
            filterPill.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 8),
            filterPill.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
        ])

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        let root = NSView()
        for sub in [scrollView, bottomBar, emptyLabel] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 24),
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 20),
        ])
        view = root
        applyIconSize()
        applySnapshot()   // The shared model usually already has a snapshot (the list loads first), so present it directly
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // Another pane may have changed the app-level icon size preference: align on appear
        let preferred = Self.preferredIconSize
        if preferred != iconSize {
            iconSize = preferred
            sizeSlider.doubleValue = Double(preferred)
            applyIconSize()
        }
    }

    // MARK: Icon size (slider, app-level UserDefaults)

    @objc private func sliderChanged(_ sender: NSSlider) {
        let size = CGFloat(sender.doubleValue.rounded())
        guard size != iconSize else { return }
        iconSize = size
        Self.preferredIconSize = size
        applyIconSize()
    }

    private func applyIconSize() {
        flowLayout.itemSize = NSSize(width: iconSize + 32, height: iconSize + 42)
        flowLayout.invalidateLayout()
    }

    // MARK: Snapshot presentation

    private var lastSnapshotDirectory: URL?

    private func applySnapshot() {
        if lastSnapshotDirectory != model.directory {
            lastSnapshotDirectory = model.directory
            cancelDecorationWork()
        }
        // Same-directory refreshes clear the thumbnail overlay too: file contents may have changed (the IconThumb cache key includes mtime)
        thumbOverlay.removeAll()
        emptyLabel.isHidden = true
        let kept = selectionURLCache   // I-32: source of truth for the actual pre-delete selection (not the shifted selectionIndexPaths)
        rebuildSections()              // M26 v2: rebuild the section ↔ model mapping when grouped (before reloadData)
        collectionView.reloadData()
        select(urls: Array(kept), scroll: false)   // An empty set goes through too → deselectAll clears explicitly (deleted items don't "drift" onto new ones)
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

    /// Redraws visible items only (cut dimming changed; no rebuild or disk re-read needed)
    func redraw() {
        for ip in collectionView.indexPathsForVisibleItems() {
            guard let cell = collectionView.item(at: ip) as? FileIconItem,
                  let file = fileItem(at: ip) else { continue }
            let cut = coordinator?.isCut(file.url) ?? false
            cell.configure(icon: thumbOverlay[file.url] ?? Formatters.fullIcon(for: file),
                           name: file.name, dimmed: file.isHidden || cut)
        }
    }

    // MARK: Grouping conversions (M26 v2): the single source of truth for section ↔ model index mapping

    private var groupingActive: Bool { FileGrouping.active(model.sort) }

    /// Rebuilds the section sequence from the current model.items (already sorted by the reader) + refreshes the filter pill.
    private func rebuildSections() {
        if groupingActive {
            var gs = FileGrouping.buckets(model.items, key: model.sort.key, ascending: model.sort.ascending)
            if let only = groupFilterKey, !gs.contains(where: { $0.key == only }) { groupFilterKey = nil }
            if let only = groupFilterKey { gs = gs.filter { $0.key == only } }
            sections = gs
        } else {
            sections = [FileGrouping.Group(key: "__all__", title: "", indices: Array(model.items.indices))]
            groupFilterKey = nil
        }
        updateFilterPill()
        flowLayout.headerReferenceSize = groupingActive ? NSSize(width: 100, height: 28) : .zero
        flowLayout.invalidateLayout()
    }

    /// section+item index → model.items index
    private func modelIndex(at ip: IndexPath) -> Int? {
        guard sections.indices.contains(ip.section) else { return nil }
        let sec = sections[ip.section]
        guard sec.indices.indices.contains(ip.item) else { return nil }
        return sec.indices[ip.item]
    }

    private func fileItem(at ip: IndexPath) -> FileItem? {
        guard let i = modelIndex(at: ip), model.items.indices.contains(i) else { return nil }
        return model.items[i]
    }

    /// model index → indexPath (in a filtered-out section → nil)
    private func indexPath(forModelIndex idx: Int) -> IndexPath? {
        for (s, sec) in sections.enumerated() {
            if let pos = sec.indices.firstIndex(of: idx) { return IndexPath(item: pos, section: s) }
        }
        return nil
    }

    private func updateFilterPill() {
        if let only = groupFilterKey, let g = sections.first(where: { $0.key == only }) {
            filterPill.title = L10n.f("group.filter.pill", g.title)
            filterPill.isHidden = false
        } else {
            filterPill.isHidden = true
        }
    }

    /// Rebuilds sections + reloads (preserving URL selection); shared by collapse/filter/toggle changes
    private func rebuildAndReloadPreservingSelection() {
        let kept = selectionURLCache
        rebuildSections()
        collectionView.reloadData()
        select(urls: Array(kept), scroll: false)
    }

    @objc func toggleGrouping(_ sender: Any?) {
        Preferences.listGrouping.toggle()
        NotificationCenter.default.post(name: Notification.Name.hspaceGroupingChanged, object: nil)
    }

    @objc private func groupingChanged(_ note: Notification) {
        rebuildAndReloadPreservingSelection()
    }

    private func applyGroupFilter(key: String) { groupFilterKey = key; rebuildAndReloadPreservingSelection() }
    @objc private func clearGroupFilter(_ sender: Any?) { groupFilterKey = nil; rebuildAndReloadPreservingSelection() }
    @objc private func groupFilterOnly(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        applyGroupFilter(key: key)
    }
    @objc private func groupFilterAll(_ sender: Any?) { groupFilterKey = nil; rebuildAndReloadPreservingSelection() }

    /// UISelfTest (M26 v2): number of visible sections (grouping on = group count; off = 1)
    var uiTestSectionCount: Int { sections.count }
    var uiTestGroupTitles: [String] { sections.map(\.title) }
    /// The group header really has a background ("printed on a background strip")
    var uiTestGroupHeaderIsBackgroundBar: Bool {
        let h = IconGroupHeaderView(frame: .zero)
        guard let bg = h.layer?.backgroundColor else { return false }
        return bg.alpha > 0.01
    }
    /// Whether the group header still accepts clicks (collapsing was dropped → must be false)
    var uiTestGroupHeaderIsClickable: Bool {
        IconGroupHeaderView.instancesRespond(to: #selector(NSView.mouseDown(with:)))
            && IconGroupHeaderView.uiTestOverridesMouseDown
    }
    func uiTestFilterFirstGroup() { if let k = sections.first?.key { applyGroupFilter(key: k) } }
    func uiTestClearFilter() { groupFilterKey = nil; rebuildAndReloadPreservingSelection() }

    /// UISelfTest (I-59): clears the selection (simulates clicking empty grid space)
    func uiTestClearSelection() { collectionView.deselectAll(nil) }
    var uiTestFilterPillVisible: Bool { !filterPill.isHidden }

    // MARK: On-demand thumbnails (visible items only, cancelled on scroll-out; north star of zero waste)

    @objc private func scrollBoundsChanged(_ note: Notification) {
        refreshVisibleDecorations()
    }

    /// Cancels all in-flight thumbnail requests (called on tab/pane suspend and directory switch; backfilled results are kept)
    func cancelDecorationWork() {
        thumbTasks.values.forEach { $0.cancel() }
        thumbTasks.removeAll()
    }

    /// Issues missing thumbnail requests for visible items; cancels all in-flight requests no longer visible
    func refreshVisibleDecorations() {
        guard view.window != nil, !model.items.isEmpty else { return }
        var wanted = Set<URL>()
        for ip in collectionView.indexPathsForVisibleItems() {
            guard let item = fileItem(at: ip) else { continue }
            if thumbOverlay[item.url] == nil, wantsThumbnail(item) {
                wanted.insert(item.url)
                requestThumbnail(item.url)
            }
        }
        for (url, task) in thumbTasks where !wanted.contains(url) {
            task.cancel(); thumbTasks[url] = nil
        }
    }

    /// Types worth a content thumbnail: images/audio-video/PDF; directories and app bundles use type icons (no QuickLook request)
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

    private func requestThumbnail(_ url: URL) {
        guard thumbTasks[url] == nil else { return }
        // Always request at the 128pt ceiling (x2 pixels internally): slider scaling affects display only and doesn't regenerate repeatedly
        thumbTasks[url] = Task { [weak self] in
            let cg = await Engines.iconThumb.thumbnail(for: url, size: 128)
            guard let self, !Task.isCancelled else { return }
            self.thumbTasks[url] = nil
            guard let cg else { return }
            let image = NSImage(cgImage: cg, size: NSSize(width: 128, height: 128))
            self.thumbOverlay[url] = image
            guard let idx = self.model.items.firstIndex(where: { $0.url == url }),
                  let ip = self.indexPath(forModelIndex: idx),
                  let cell = self.collectionView.item(at: ip) as? FileIconItem
            else { return }
            cell.setIcon(image)
        }
    }

    // MARK: Selection state

    var selectedItems: [FileItem] {
        collectionView.selectionIndexPaths.sorted().compactMap { fileItem(at: $0) }
    }
    var selectedURLs: [URL] { selectedItems.map(\.url) }

    /// UISelfTest (I-32): raw selection count at the view layer (queries collectionView directly, bypassing model mapping); verifies a real clear after delete
    var uiTestRawSelectionCount: Int { collectionView.selectionIndexPaths.count }

    /// Restores the selection from a URL set (view mode migration / keeping it over FSEvents refresh); matches standardized paths (trailing-slash differences across sources, I-39);
    /// goes through the group mapping via indexPath(forModelIndex:) (items in collapsed/filtered groups naturally drop out).
    func select(urls: [URL], scroll: Bool = true) {
        let wanted = Set(urls.map { $0.standardizedFileURL.path })
        var paths = Set<IndexPath>()
        for (i, item) in model.items.enumerated()
        where wanted.contains(item.url.standardizedFileURL.path) {
            if let ip = indexPath(forModelIndex: i) { paths.insert(ip) }
        }
        collectionView.deselectAll(nil)
        if !paths.isEmpty {
            collectionView.selectItems(at: paths, scrollPosition: scroll ? .nearestHorizontalEdge : [])
        }
        // Programmatic select/deselect doesn't call the delegate → manually sync the cache to the exact matched set (empty means empty)
        selectionURLCache = Set(paths.compactMap { fileItem(at: $0)?.url })
    }

    // MARK: Reveal (select after creating; the icon view has no inline rename, so rename is ignored: honest, no faking)

    func prepareReveal(_ url: URL, rename: Bool) { pendingReveal = (url, rename) }

    func takePendingReveal() -> (url: URL, rename: Bool)? {
        defer { pendingReveal = nil }
        return pendingReveal
    }

    /// UISelfTest (I-56): whether a pending reveal is still set (verifies the pending target really moved on a view mode switch)
    var uiTestHasPendingReveal: Bool { pendingReveal != nil }

    private func revealPendingIfPossible() {
        // Standardized path compare + case-insensitive fallback, unified in model.itemIndex(forURL:) (same fix as I-39/I-55)
        guard let pending = pendingReveal else { return }
        guard let idx = model.itemIndex(forURL: pending.url),
              let ip = indexPath(forModelIndex: idx)
        else {
            // Target directory loaded but target not found: void the pending target, or it would later "ghost-select" and steal keyboard focus
            if model.isLoadedDirectory(forParentOf: pending.url) { pendingReveal = nil }
            return
        }
        pendingReveal = nil
        collectionView.deselectAll(nil)
        collectionView.selectItems(at: [ip], scrollPosition: .nearestHorizontalEdge)
        selectionURLCache = [pending.url]   // I-32: sync the cache source of truth on programmatic selection
        view.window?.makeFirstResponder(collectionView)   // I-48: focus the grid so the selection shows the blue accent (otherwise an unemphasized gray that's nearly invisible)
        onSelectionChange?()
    }

    // MARK: Open behaviour (same semantics as the list: files open in the system default app; folders navigate within the pane)

    private func open(_ item: FileItem) {
        if item.isDirectory && !item.isPackage {
            onNavigate?(item.url)
        } else {
            coordinator?.recordAccess(item.url)   // M28: opening a file = one usage record
            NSWorkspace.shared.open(item.url)
        }
    }

    // MARK: Context menu (reuses the builder; unimplemented actions gray out automatically)

    private func buildMenu() -> NSMenu {
        FileContextMenuBuilder.menu(selection: selectedItems, directory: model.directory, target: self)
    }

    // MARK: Menu commands (responder chain; semantics match the list)

    @objc func toggleHiddenFiles(_ sender: Any?) { model.includeHidden.toggle() }
    @objc func refresh(_ sender: Any?) { model.reload() }

    @objc func copyItems(_ sender: Any?) { coordinator?.copy(selectedURLs) }
    @objc func cutItems(_ sender: Any?) { coordinator?.cut(selectedURLs) }
    /// Put Back (only inside the Trash; works only for items in the ledger, others honestly grayed out)
    @objc func putBackItems(_ sender: Any?) { coordinator?.putBack(selectedURLs) }

    @objc func pasteItems(_ sender: Any?) { coordinator?.paste(into: model.directory, revealIn: self) }
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
    @objc func newFolderHere(_ sender: Any?) { coordinator?.newFolder(in: model.directory, revealIn: self) }
    @objc func newFileHere(_ sender: Any?) { coordinator?.newFile(in: model.directory, revealIn: self) }
    @objc func copyToOtherPane(_ sender: Any?) { coordinator?.copyToOtherPane(selectedURLs) }
    @objc func moveToOtherPane(_ sender: Any?) { coordinator?.moveToOtherPane(selectedURLs) }

    @objc func openSelected(_ sender: Any?) { selectedItems.forEach { open($0) } }

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
        let target = selectedURLs.first ?? model.directory
        InfoPanel.show(for: target)
    }

    @objc func openInTerminal(_ sender: Any?) {
        TerminalResolver.open(selectedItems.first(where: { $0.isDirectory })?.url ?? model.directory)
    }

    @objc func showPackageContents(_ sender: Any?) {
        guard let pkg = selectedItems.first(where: { $0.isPackage }) else { return }
        onNavigate?(pkg.url)
    }

    // MARK: Quick Look (space toggles; same responder-chain panel control as the list)

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

// MARK: - Menu validation (enable/disable by selection state; rename unimplemented → not responding grays it out automatically)

extension FileIconGridViewController: @preconcurrency NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let hasSelection = !collectionView.selectionIndexPaths.isEmpty
        switch menuItem.action {
        // Copy Path is always available: with no selection it falls back to the current directory (same as the list view)
        case #selector(copyPath(_:)):
            return true
        case #selector(putBackItems(_:)):
            return TrashLocation.isInsideTrash(model.directory) && !selectedURLs.isEmpty
        case #selector(copyItems(_:)), #selector(cutItems(_:)),
             #selector(duplicateItems(_:)), #selector(moveToTrash(_:)), #selector(openSelected(_:)),
             #selector(copyToOtherPane(_:)), #selector(moveToOtherPane(_:)),
             #selector(copy(_:)), #selector(cut(_:)):
            return hasSelection
        // Inside the Trash, disable actions that "bring live files in" (Finder disables them too). These became reachable only once
        // the Trash was browsable: files put here have no undo and no Put Back metadata,
        // so emptying the Trash later would really lose them. Same fix across all three views.
        case #selector(pasteItems(_:)), #selector(paste(_:)):
            if TrashLocation.isInsideTrash(model.directory) { return false }
            return NSPasteboard.general.canReadObject(forClasses: [NSURL.self],
                                                      options: [.urlReadingFileURLsOnly: true])
        case #selector(newFolderHere(_:)), #selector(newFileHere(_:)):
            return !TrashLocation.isInsideTrash(model.directory)
        case #selector(toggleGrouping(_:)):
            menuItem.state = Preferences.listGrouping ? .on : .off
            return true
        default:
            return true
        }
    }
}

// MARK: - Data source / delegate

extension FileIconGridViewController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func numberOfSections(in collectionView: NSCollectionView) -> Int { sections.count }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        guard sections.indices.contains(section) else { return 0 }
        return sections[section].indices.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: FileIconItem.reuseID, for: indexPath)
        guard let cell = item as? FileIconItem, let file = fileItem(at: indexPath) else { return item }
        let cut = coordinator?.isCut(file.url) ?? false
        // Fast path shows the type icon first; a delivered content thumbnail is used directly (upgrade path in requestThumbnail)
        cell.configure(icon: thumbOverlay[file.url] ?? Formatters.fullIcon(for: file),
                       name: file.name, dimmed: file.isHidden || cut)
        return item
    }

    /// Group header: "Aug 2026" + item count printed on a background strip. Not collapsible (owner request: no folding);
    /// right-click can still filter by group (a separate feature, not dropped).
    func collectionView(_ collectionView: NSCollectionView,
                        viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        let header = collectionView.makeSupplementaryView(
            ofKind: kind, withIdentifier: IconGroupHeaderView.reuseID, for: indexPath) as! IconGroupHeaderView
        guard groupingActive, sections.indices.contains(indexPath.section) else {
            header.configure(title: "", count: 0); return header
        }
        let g = sections[indexPath.section]
        header.configure(title: g.title, count: g.indices.count)
        header.menuProvider = { [weak self] in self?.buildGroupMenu(key: g.key) }
        return header
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

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        selectionDidChange()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        selectionDidChange()
    }

    private func selectionDidChange() {
        // I-32: user clicks arrive here (didSelect/didDeselect) → source-of-truth bookkeeping
        selectionURLCache = Set(selectedURLs)
        onSelectionChange?()
        if QLPreviewPanel.sharedPreviewPanelExists(),
           let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.reloadData()
        }
    }

    // MARK: Drag source (can drag to Finder/other apps/another pane/sidebar bookmarks/stash shelf)

    func collectionView(_ collectionView: NSCollectionView,
                        pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
        fileItem(at: indexPath)?.url as NSURL?
    }

    // MARK: Drop target (BG-1: the destination only sends intent; kind decision and submission live in the coordinator)

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: any NSDraggingInfo,
                        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        guard let urls = Self.draggedFileURLs(draggingInfo), !urls.isEmpty else { return [] }
        // Normalize the destination: directory item = drop into that folder; file item/empty space = drop into the current directory
        var target = model.directory
        let dropItem = fileItem(at: proposedIndexPath.pointee as IndexPath)
        if dropOperation.pointee == .on, let f = dropItem, f.isDirectory, !f.isPackage {
            target = f.url
        } else {
            dropOperation.pointee = .before
        }
        // Refuse dropping a directory into itself/a descendant
        guard urls.allSatisfy({ !FileOpsCoordinator.isSelfOrDescendant(destination: target, ofSource: $0) }) else {
            return []
        }
        guard !DropFeedback.refusesTrash(target, in: view.window) else { return [] }
        // Same decision as the submission in dropTransfer (drag preference + ⌥ + volume), so the cursor cannot disagree with it
        let willMove = FileOpsCoordinator.effectiveMove(
            urls: urls, into: target, optionCopy: draggingInfo.draggingSourceOperationMask == .copy)
        return DropFeedback.operation(willMove: willMove, urls: urls, target: target)
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: any NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        guard let urls = Self.draggedFileURLs(draggingInfo), !urls.isEmpty else { return false }
        var target = model.directory
        if dropOperation == .on, let f = fileItem(at: indexPath), f.isDirectory, !f.isPackage {
            target = f.url
        }
        coordinator?.dropTransfer(urls: urls, into: target,
                                  forceCopy: draggingInfo.draggingSourceOperationMask == .copy)
        return true
    }

    private static func draggedFileURLs(_ info: any NSDraggingInfo) -> [URL]? {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL]
    }
}

// MARK: - Quick Look data source/delegate (multi-selection preview; zoom animation anchored to the item's icon area)

extension FileIconGridViewController: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        selectedItems.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let urls = selectedURLs
        guard index >= 0, index < urls.count else { return nil }
        return urls[index] as NSURL
    }

    /// Arrow keys on the panel go back to the grid first (all four directions advance the selection, Finder feel)
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, (123...126).contains(Int(event.keyCode)) else { return false }
        collectionView.keyDown(with: event)
        return true
    }

    /// Zoom animation origin = the item's icon area
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        if quickLookDismissing { return .zero }
        guard let url = (item as? NSURL) as URL?,
              let idx = model.items.firstIndex(where: { $0.url == url }),
              let ip = indexPath(forModelIndex: idx),
              let attrs = collectionView.layoutAttributesForItem(at: ip),
              let window = view.window else { return .zero }
        let rect = collectionView.convert(attrs.frame, to: nil)
        return window.convertToScreen(rect)
    }
}

/// Icon view group header (NSCollectionView section header, M26 v2):
/// "Aug 2026" + item count printed on a background strip. **Not collapsible** (owner request: like QSpace, no folding).
/// The disclosure triangle and block click were removed: an arrow that looks like a button but does nothing is worse than no arrow.
/// Right-click still offers the "Show Only This Group / Show All Groups" filter menu (a separate feature, not dropped).
@MainActor
final class IconGroupHeaderView: NSView {
    static let reuseID = NSUserInterfaceItemIdentifier("iconGroupHeader")

    var menuProvider: (() -> NSMenu?)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)  // tabular-nums
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        for v in [titleLabel, countLabel] { addSubview(v) }
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

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

    /// Self-test check: whether this class itself overrides mouseDown (must be false since collapsing was dropped).
    /// Testing "has this method" is useless, since NSView has it anyway; what matters is whether **this class** overrides it.
    static var uiTestOverridesMouseDown: Bool {
        class_getInstanceMethod(IconGroupHeaderView.self, #selector(NSView.mouseDown(with:)))
            != class_getInstanceMethod(NSView.self, #selector(NSView.mouseDown(with:)))
    }
}
