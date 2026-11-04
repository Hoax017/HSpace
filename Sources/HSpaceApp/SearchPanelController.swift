import AppKit
import UniformTypeIdentifiers
import SearchEngine
import Frecency

/// Kind filter (filters results client-side, without re-running the search)
private enum SearchKindFilter: Int, CaseIterable {
    case all, folder, image, document, movie, audio, archive

    var titleKey: String {
        switch self {
        case .all: "search.kind.all"
        case .folder: "search.kind.folder"
        case .image: "search.kind.image"
        case .document: "search.kind.document"
        case .movie: "search.kind.movie"
        case .audio: "search.kind.audio"
        case .archive: "search.kind.archive"
        }
    }

    func matches(_ hit: SearchHit) -> Bool {
        switch self {
        case .all: true
        case .folder: hit.isDirectory
        case .image: conforms(hit, to: .image)
        case .document: conforms(hit, to: .text) || conforms(hit, to: .pdf)
        case .movie: conforms(hit, to: .movie)
        case .audio: conforms(hit, to: .audio)
        case .archive: conforms(hit, to: .archive)
        }
    }

    private func conforms(_ hit: SearchHit, to type: UTType) -> Bool {
        guard let id = hit.contentTypeID, let t = UTType(id) else { return false }
        return t.conforms(to: type)
    }
}

/// Borderless panel that can become key (borderless refuses key by default; the input field needs it)
@MainActor
private final class SearchPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Results table: Return = locate, Esc = close panel, right-click = context menu (the rest stays default: arrow keys/double-click)
@MainActor
private final class SearchResultTableView: NSTableView {
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?
    /// Context menu provider: takes the clicked row (-1 means blank space; returning nil shows no menu)
    var menuProvider: ((Int) -> NSMenu?)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onReturn?()   // Return / Enter
        case 53: onEscape?()       // Esc
        default: super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        // Right-click on an unselected row -> make it the sole selection first (Finder semantics)
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes([row], byExtendingSelection: false)
        }
        return menuProvider?(row)
    }
}

/// Focused search panel (QSpace-style overlay): a borderless floating window centered above the main window.
/// Consumes the SearchEngine stream read-only (BG-1: this layer has zero file write APIs);
/// Return-to-locate goes up through a callback to MainWindowController for navigation; double-click uses the system default open.
@MainActor
final class SearchPanelController: NSObject {
    static let shared = SearchPanelController()

    private let panel: SearchPanel
    private let field = NSTextField()
    private let scopePopup = NSPopUpButton()
    private let spinner = NSProgressIndicator()
    private let nameCheck = NSButton(checkboxWithTitle: L10n.t("search.names"), target: nil, action: nil)
    private let contentCheck = NSButton(checkboxWithTitle: L10n.t("search.contents"), target: nil, action: nil)
    private let hiddenCheck = NSButton(checkboxWithTitle: L10n.t("search.includeHidden"), target: nil, action: nil)
    private let kindPopup = NSPopUpButton()
    private let tableView = SearchResultTableView()
    private let emptyLabel = NSTextField(labelWithString: L10n.t("search.empty"))
    /// Result cap notice ("Showing only the first N results, refine your keywords"): the engine stops both channels at this cap, ruling out hangs
    private let truncationLabel = NSTextField(labelWithString: "")

    private let engine = SearchEngine()
    /// All hits (accumulated from the stream) and the filtered display set
    private var allHits: [SearchHit] = []
    private var hits: [SearchHit] = []
    private var searchTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var isSearching = false
    /// I-40: search root for local scope (for "nearest to root first" sorting; nil for global search, which keeps arrival order)
    private var searchRoot: URL?
    /// Two prefix forms of the root: as given + with symlinks resolved. The Spotlight channel reports resolved paths
    /// (/tmp⟷/private/tmp etc.), and a single unresolved prefix would mark the whole main channel "outside root" and sink it
    private var rootPrefixes: [String] = []
    /// Depth computed once per hit (key = url.path); reused by batch merges/filter re-sorts, with no full recomputation
    private var depthCache: [String: Int] = [:]

    /// M28 usage-based ranking: injected frecency carrier (set once by AppDelegate, same instance as app-wide accounting)
    var frecencyStore: FrecencyStore?
    /// Frecency snapshot for this search (awaited once at the start of the search task; stable during the search, hits scored synchronously)
    private var frecencySnapshot: [String: FrecencyEntry] = [:]
    /// Whether this search uses smart ranking (preference on and a query present); fixed during the search
    private var smartSortActive = false
    /// Query for this search (used for smart match scoring)
    private var currentQuery = ""
    /// Blended score computed once per hit (key = url.path)
    private var scoreCache: [String: Double] = [:]

    /// "Current folder" and locate callback captured on open (re-injected on every show)
    private var currentDirectory: URL?
    private var onReveal: ((URL) -> Void)?
    /// Add-to-stash callback (injected by MainWindowController through StashShelfController; nil = unreachable, so the menu omits the item, FG-1)
    private var onStash: (([URL]) -> Void)?

    override private init() {
        panel = SearchPanel(contentRect: NSRect(x: 0, y: 0, width: 880, height: 460),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = true
        panel.onCancel = { [weak self] in self?.closePanel() }
        buildContent()
        // Auto-close on focus loss (click outside the panel)
        NotificationCenter.default.addObserver(self, selector: #selector(panelResignedKey(_:)),
                                               name: NSWindow.didResignKeyNotification, object: panel)
    }

    // MARK: Open / close

    /// ⌘F: scopeGlobal=false (current folder); ⌥⌘F: scopeGlobal=true (global)
    func show(scopeGlobal: Bool, currentDirectory: URL, attachedTo window: NSWindow?,
              onReveal: @escaping (URL) -> Void,
              onStash: (([URL]) -> Void)? = nil) {
        self.currentDirectory = currentDirectory
        self.onReveal = onReveal
        self.onStash = onStash
        scopePopup.selectItem(at: scopeGlobal ? 0 : 1)
        position(over: window)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        // Reopened with existing keywords in a different scope -> search again at once in the new scope
        restartSearch()
    }

    private func position(over window: NSWindow?) {
        let ref = window?.frame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let size = panel.frame.size
        let origin = NSPoint(x: ref.midX - size.width / 2,
                             y: ref.maxY - size.height - 96)
        panel.setFrameOrigin(origin)
    }

    private func closePanel() {
        searchTask?.cancel()
        debounceTask?.cancel()
        spinner.stopAnimation(nil)
        isSearching = false
        panel.orderOut(nil)
    }

    @objc private func panelResignedKey(_ note: Notification) {
        closePanel()
    }

    // MARK: Search execution (search as you type, 300ms debounce; streaming append)

    private func scheduleSearch() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.restartSearch()
        }
    }

    private func restartSearch() {
        searchTask?.cancel()
        allHits = []
        hits = []
        tableView.reloadData()
        emptyLabel.isHidden = true
        let query = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            spinner.stopAnimation(nil)
            isSearching = false
            return
        }
        isSearching = true
        spinner.startAnimation(nil)
        currentQuery = query
        smartSortActive = Preferences.searchSmartSort
        scoreCache = [:]
        let scope: SearchRequest.Scope = scopePopup.indexOfSelectedItem == 0
            ? .global
            : .directory(currentDirectory ?? FileManager.default.homeDirectoryForCurrentUser)
        setSearchRoot(scopePopup.indexOfSelectedItem == 0
            ? nil
            : (currentDirectory ?? FileManager.default.homeDirectoryForCurrentUser))
        let request = SearchRequest(query: query, scope: scope,
                                    searchNames: nameCheck.state == .on,
                                    searchContents: contentCheck.state == .on,
                                    includeHidden: hiddenCheck.state == .on)
        searchTask = Task { [weak self] in
            guard let self else { return }
            // M28: take a frecency snapshot once before ranking (ahead of the stream, so the first batch already ranks by usage, stable during the search)
            self.frecencySnapshot = await self.frecencyStore?.snapshot() ?? [:]
            guard !Task.isCancelled else { return }
            for await batch in engine.search(request) {
                guard !Task.isCancelled else { return }
                self.appendResults(batch)
            }
            guard !Task.isCancelled else { return }
            self.finishSearch()
        }
    }

    private func appendResults(_ batch: [SearchHit]) {
        allHits.append(contentsOf: batch)
        let filter = selectedKindFilter
        let visible = filter == .all ? batch : batch.filter { filter.matches($0) }
        guard !visible.isEmpty else { return }
        // Selection memory (I-38): remember the current selection by URL before changing
        let selectedURL = tableView.selectedRow >= 0 && tableView.selectedRow < hits.count
            ? hits[tableView.selectedRow].url : nil
        // Smart ranking (M28) or local root-nearness: sort the new batch and merge linearly (O(n) amortized, avoids rebuilding everything).
        // Global + smart off: append in arrival order in place (O(1)).
        if smartSortActive || searchRoot != nil {
            hits = merged(hits, visible.sorted(by: rankLess))
        } else {
            hits.append(contentsOf: visible)
        }
        tableView.reloadData()
        restoreSelection(selectedURL)
        updateTruncationHint()
    }

    /// I-38: after reload, restore the selection by URL and keep it visible (each streamed batch's reloadData used to wipe the user's selection)
    private func restoreSelection(_ url: URL?) {
        guard let url, let row = hits.firstIndex(where: { $0.url == url }) else { return }
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    /// Whole result set replacement (for kindChanged / test probes); keeps the selection
    private func setHits(_ newHits: [SearchHit]) {
        let selectedURL = tableView.selectedRow >= 0 && tableView.selectedRow < hits.count
            ? hits[tableView.selectedRow].url : nil
        hits = newHits
        tableView.reloadData()
        restoreSelection(selectedURL)
        updateTruncationHint()
    }

    /// At the hard result cap, shows "Showing only the first N results, refine your keywords" (the engine has stopped both channels at this cap, so CPU stays bounded)
    private func updateTruncationHint() {
        truncationLabel.isHidden = allHits.count < SearchLimits.maxResults
    }

    // MARK: I-40 local ordering (nearest to root first: root's direct children first, deeper level by level, same level in path dictionary order)

    /// Change root: resets prefix forms and depth cache (shared by restartSearch / test probes)
    private func setSearchRoot(_ root: URL?) {
        searchRoot = root
        depthCache = [:]
        guard let root else {
            rootPrefixes = []
            return
        }
        let raw = root.standardizedFileURL.path
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL.path
        rootPrefixes = raw == resolved
            ? [dirPrefix(raw)]
            : [dirPrefix(raw), dirPrefix(resolved)]
    }

    private func dirPrefix(_ path: String) -> String { path == "/" ? "/" : path + "/" }

    /// Hit depth relative to the root (direct child = 1); no match with either root form -> outside root, sinks to the bottom (.max)
    private func depth(of hit: SearchHit) -> Int {
        let key = hit.url.path
        if let cached = depthCache[key] { return cached }
        let p = hit.url.standardizedFileURL.path
        var d = Int.max
        for prefix in rootPrefixes where p.hasPrefix(prefix) {
            d = p.dropFirst(prefix.count).split(separator: "/").count
            break
        }
        depthCache[key] = d
        return d
    }

    private func inRankOrder(_ a: SearchHit, _ b: SearchHit) -> Bool {
        let da = depth(of: a), db = depth(of: b)
        return da != db
            ? da < db
            : a.url.path.localizedStandardCompare(b.url.path) == .orderedAscending
    }

    // MARK: M28 smart ranking (blend of frecency + match quality; takes over global and local when the preference is on)

    /// Blended score (computed once per hit and cached): match quality + frecency (snapshot, stable during the search).
    private func smartScore(of hit: SearchHit) -> Double {
        let key = hit.url.path
        if let c = scoreCache[key] { return c }
        let match = SearchRanking.matchScore(query: currentQuery, name: hit.name, path: hit.url.path) ?? 0
        let frec = frecencySnapshot[hit.url.standardizedFileURL.path]
            .map { SearchRanking.frecencyScore($0, now: Date()) } ?? 0
        let s = SearchRanking.fused(match: match, frecency: frec, queryLen: currentQuery.count)
        scoreCache[key] = s
        return s
    }

    /// Sort comparator: smart on -> blended score descending (tie-break by root nearness for local, else dictionary order); smart off -> the original inRankOrder.
    private func rankLess(_ a: SearchHit, _ b: SearchHit) -> Bool {
        guard smartSortActive else { return inRankOrder(a, b) }
        let sa = smartScore(of: a), sb = smartScore(of: b)
        if sa != sb { return sa > sb }
        if searchRoot != nil {
            let da = depth(of: a), db = depth(of: b)
            if da != db { return da < db }
        }
        return a.url.path.localizedStandardCompare(b.url.path) == .orderedAscending
    }

    /// Linear merge of two sorted arrays (hits invariant: always ordered by rankLess under smart/local)
    private func merged(_ a: [SearchHit], _ b: [SearchHit]) -> [SearchHit] {
        var out: [SearchHit] = []
        out.reserveCapacity(a.count + b.count)
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if rankLess(b[j], a[i]) {
                out.append(b[j]); j += 1
            } else {
                out.append(a[i]); i += 1
            }
        }
        out.append(contentsOf: a[i...])
        out.append(contentsOf: b[j...])
        return out
    }

    private func finishSearch() {
        isSearching = false
        spinner.stopAnimation(nil)
        updateEmptyState()
    }

    private func updateEmptyState() {
        let query = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        emptyLabel.isHidden = isSearching || hits.isEmpty == false || query.isEmpty
    }

    private var selectedKindFilter: SearchKindFilter {
        SearchKindFilter(rawValue: kindPopup.indexOfSelectedItem) ?? .all
    }

    // MARK: Control actions

    @objc private func scopeChanged(_ sender: Any?) { restartSearch() }

    @objc private func channelChanged(_ sender: NSButton) {
        // Name/content cannot both be off (FG: no dead state that can only give empty results)
        if nameCheck.state == .off, contentCheck.state == .off {
            sender.state = .on
            NSSound.beep()
            return
        }
        restartSearch()
    }

    @objc private func hiddenChanged(_ sender: Any?) { restartSearch() }

    @objc private func kindChanged(_ sender: Any?) {
        let filter = selectedKindFilter
        let base = filter == .all ? allHits : allHits.filter { filter.matches($0) }
        // Switching the filter is an explicit user action: one full sort is acceptable (depth/blended scores are cached, so only comparison cost)
        setHits((smartSortActive || searchRoot != nil) ? base.sorted(by: rankLess) : base)
        updateEmptyState()
    }

    /// Double-click: directories (not packages) are entered in the current window's active pane (I-18: no more round trip through LS opening a new window);
    /// files/packages keep opening with the system default app
    @objc private func didDoubleClick(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < hits.count else { return }
        let url = hits[row].url
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
        if exists, isDir.boolValue, !isPackage {
            closePanel()
            onReveal?(url)
        } else {
            if let store = frecencyStore { Task { await store.record(url) } }   // M28: opening a search result counts as usage
            NSWorkspace.shared.open(url)
        }
    }

    /// Return = navigate the active pane to the containing directory and select
    private func revealSelection() {
        let row = tableView.selectedRow >= 0 ? tableView.selectedRow : (hits.isEmpty ? -1 : 0)
        guard row >= 0, row < hits.count else { NSSound.beep(); return }
        let url = hits[row].url
        closePanel()
        onReveal?(url)
    }

    // MARK: Result row context menu (I-31: trimmed for the search context: holds hits[URL] rather than a model; anything that depends on coordinator is left out, FG-1 no fake items)

    /// Clicked row -> hit, build the menu (-1 or out of range returns nil: the search panel has no blank-space directory menu)
    private func buildMenu(clickedRow row: Int) -> NSMenu? {
        guard row >= 0, row < hits.count else { return nil }
        return menu(for: hits[row])
    }

    /// Result row context menu. Minimal set: Open / Locate in HSpace / Copy Path / Add to Stash (when reachable) / Get Info.
    /// Each item's representedObject carries the hit URL; the action target is this controller (exposed so UISelfTest can build and assert directly).
    func menu(for hit: SearchHit) -> NSMenu {
        let menu = NSMenu()
        let url = hit.url

        addMenuItem(menu, "menu.open", #selector(openHit(_:)), url: url,
                    symbol: hit.isDirectory ? "arrow.forward.square" : "arrow.up.forward.app")
        // Locate in HSpace: through the onReveal chain (injected at show); left out if unreachable (FG-1)
        if onReveal != nil {
            addMenuItem(menu, "search.reveal", #selector(revealHit(_:)), url: url,
                        symbol: "scope")
        }
        menu.addItem(.separator())

        addMenuItem(menu, "menu.copyPath", #selector(copyHitPath(_:)), url: url,
                    symbol: "link")
        // Add to Stash: offered only when StashShelfController is reachable (onStash is injected by MainWindowController)
        if onStash != nil {
            addMenuItem(menu, "search.addToStash", #selector(stashHit(_:)), url: url,
                        symbol: "tray.and.arrow.down")
        }
        menu.addItem(.separator())

        // Get Info: InfoPanel can be reused directly
        addMenuItem(menu, "menu.getInfo", #selector(getInfoForHit(_:)), url: url,
                    symbol: "info.circle")
        return menu
    }

    @discardableResult
    private func addMenuItem(_ menu: NSMenu, _ key: String, _ action: Selector,
                             url: URL, symbol: String) -> NSMenuItem {
        let item = NSMenuItem(title: L10n.t(key), action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = url
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        menu.addItem(item)
        return item
    }

    /// Open: directories (not packages) are located inside HSpace; files/packages use the system default app (same semantics as double-click)
    @objc private func openHit(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
        if exists, isDir.boolValue, !isPackage, onReveal != nil {
            closePanel()
            onReveal?(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Locate in HSpace: passes up the onReveal chain to MainWindowController to navigate and select
    @objc private func revealHit(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        closePanel()
        onReveal?(url)
    }

    /// Copy Path: writes to the general pasteboard (real effect: NSPasteboard content == the path)
    @objc private func copyHitPath(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.path, forType: .string)
        Toast.show(L10n.t("toast.copiedPath"), in: panel)
    }

    /// Add to Stash: lands through the injected onStash (StashShelfController.add)
    @objc private func stashHit(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onStash?([url])
    }

    /// Get Info: reuses InfoPanel
    @objc private func getInfoForHit(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        InfoPanel.show(for: url)
    }

    // MARK: UISelfTest probes (I-38 streaming keeps selection / I-40 root nearness + path column; does not touch the real search engine)

    /// Resets the result set and injects a search root (fixture-driven, bypasses the engine)
    func uiTestReset(root: URL?) {
        searchTask?.cancel()
        debounceTask?.cancel()
        setSearchRoot(root)
        allHits = []
        hits = []
        tableView.reloadData()
    }
    /// Injects a batch through the real appendResults chain (all sort/selection-keeping logic applies)
    func uiTestAppend(_ batch: [SearchHit]) { appendResults(batch) }
    func uiTestSelectRow(_ row: Int) { tableView.selectRowIndexes([row], byExtendingSelection: false) }
    var uiTestSelectedPath: String? {
        tableView.selectedRow >= 0 && tableView.selectedRow < hits.count
            ? hits[tableView.selectedRow].url.path : nil
    }
    var uiTestResultPaths: [String] { hits.map(\.url.path) }
    /// M28: injects smart ranking state (query + frecency snapshot + switch), for deterministic blended ranking checks with uiTestAppend
    func uiTestConfigureSmart(query: String, snapshot: [String: FrecencyEntry], active: Bool) {
        currentQuery = query
        frecencySnapshot = snapshot
        smartSortActive = active
        scoreCache = [:]
    }
    var uiTestTruncationVisible: Bool { !truncationLabel.isHidden }
    var uiTestResultCount: Int { hits.count }
    /// Rendered text of the first row's path cell (real-effect assertion: the path really shows, not just a tooltip)
    var uiTestFirstRowPathCellText: String? {
        guard !hits.isEmpty,
              let col = tableView.tableColumns.first(where: { $0.identifier.rawValue == "path" })
        else { return nil }
        return (tableView(tableView, viewFor: col, row: 0) as? TextCellView)?.textField?.stringValue
    }

    // MARK: Build UI (4pt grid)

    private func buildContent() {
        let root = NSVisualEffectView()
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 12
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.4).cgColor

        // —— Row 1: icon + big search field + spinner + scope switch ——
        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass",
                                              accessibilityDescription: L10n.t("search.placeholder"))!)
        icon.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor

        field.font = .systemFont(ofSize: 18)
        field.placeholderString = L10n.t("search.placeholder")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        scopePopup.addItems(withTitles: [L10n.t("search.scopeGlobal"), L10n.t("search.scopeCurrent")])
        scopePopup.font = .systemFont(ofSize: 11)
        scopePopup.controlSize = .small
        scopePopup.target = self
        scopePopup.action = #selector(scopeChanged(_:))

        // —— Row 2: channel checkboxes + kind filter ——
        for check in [nameCheck, contentCheck] {
            check.target = self
            check.action = #selector(channelChanged(_:))
            check.font = .systemFont(ofSize: 12)
        }
        nameCheck.state = .on
        contentCheck.state = .off
        hiddenCheck.state = .off
        hiddenCheck.font = .systemFont(ofSize: 12)
        hiddenCheck.target = self
        hiddenCheck.action = #selector(hiddenChanged(_:))
        hiddenCheck.toolTip = L10n.t("search.hiddenTooltip")  // headline toggle that goes beyond QSpace

        for filter in SearchKindFilter.allCases {
            kindPopup.addItem(withTitle: L10n.t(filter.titleKey))
        }
        kindPopup.font = .systemFont(ofSize: 11)
        kindPopup.controlSize = .small
        kindPopup.target = self
        kindPopup.action = #selector(kindChanged(_:))

        // —— Results table ——
        tableView.style = .plain
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 8, height: 0)
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(didDoubleClick(_:))
        tableView.onReturn = { [weak self] in self?.revealSelection() }
        tableView.onEscape = { [weak self] in self?.closePanel() }
        tableView.menuProvider = { [weak self] row in self?.buildMenu(clickedRow: row) }
        for (id, width) in [("name", CGFloat(320)), ("path", 292), ("size", 72), ("dateModified", 148)] {
            let col = NSTableColumn(identifier: .init(id))
            col.width = width
            tableView.addTableColumn(col)
        }

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        truncationLabel.stringValue = L10n.f("search.truncated", SearchLimits.maxResults)
        truncationLabel.font = .systemFont(ofSize: 11)
        truncationLabel.textColor = .secondaryLabelColor
        truncationLabel.alignment = .center
        truncationLabel.isHidden = true
        truncationLabel.wantsLayer = true
        truncationLabel.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor

        let sep1 = NSBox(); sep1.boxType = .separator
        let sep2 = NSBox(); sep2.boxType = .separator

        for sub in [icon, field, spinner, scopePopup, sep1,
                    nameCheck, contentCheck, hiddenCheck, kindPopup, sep2,
                    scroll, emptyLabel, truncationLabel] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            icon.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            field.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            spinner.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 8),
            spinner.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            scopePopup.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 8),
            scopePopup.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scopePopup.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            scopePopup.widthAnchor.constraint(equalToConstant: 120),

            sep1.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 12),
            sep1.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sep1.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            nameCheck.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            nameCheck.topAnchor.constraint(equalTo: sep1.bottomAnchor, constant: 8),
            contentCheck.leadingAnchor.constraint(equalTo: nameCheck.trailingAnchor, constant: 16),
            contentCheck.centerYAnchor.constraint(equalTo: nameCheck.centerYAnchor),
            hiddenCheck.leadingAnchor.constraint(equalTo: contentCheck.trailingAnchor, constant: 16),
            hiddenCheck.centerYAnchor.constraint(equalTo: nameCheck.centerYAnchor),
            kindPopup.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            kindPopup.centerYAnchor.constraint(equalTo: nameCheck.centerYAnchor),
            kindPopup.widthAnchor.constraint(equalToConstant: 108),

            sep2.topAnchor.constraint(equalTo: nameCheck.bottomAnchor, constant: 8),
            sep2.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sep2.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: sep2.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            // Cap notice: a strip along the bottom of the result area (thin overlay, takes no space from the list layout)
            truncationLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            truncationLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            truncationLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            truncationLabel.heightAnchor.constraint(equalToConstant: 20),
        ])
        panel.contentView = root
    }
}

// MARK: - Search field delegate (debounce trigger + key routing)

extension SearchPanelController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        scheduleSearch()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            revealSelection()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            closePanel()
            return true
        case #selector(NSResponder.moveDown(_:)):
            // ↓ moves focus to the results table
            guard !hits.isEmpty else { return true }
            panel.makeFirstResponder(tableView)
            tableView.selectRowIndexes([0], byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
            return true
        default:
            return false
        }
    }
}

// MARK: - Results table data source/delegate (reuses NameCellView/TextCellView/Formatters)

extension SearchPanelController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { hits.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let colID = tableColumn?.identifier.rawValue, row < hits.count else { return nil }
        let hit = hits[row]
        if colID == "name" {
            let cell = tableView.makeView(withIdentifier: .init("searchName"), owner: nil) as? NameCellView
                ?? NameCellView(identifier: .init("searchName"))
            let icon = NSWorkspace.shared.icon(forFile: hit.url.path)
            icon.size = NSSize(width: 16, height: 16)
            cell.configure(icon: icon, name: hit.name, dimmed: false)
            cell.toolTip = hit.url.path  // same-name results are told apart by path
            return cell
        }
        let cell = tableView.makeView(withIdentifier: .init("searchText"), owner: nil) as? TextCellView
            ?? TextCellView(identifier: .init("searchText"))
        switch colID {
        case "path":
            // I-40: permanent path column (same-name results no longer rely on hover alone); middle truncation keeps both the root and nearest parent
            let parent = hit.url.deletingLastPathComponent().path
            cell.configure((parent as NSString).abbreviatingWithTildeInPath, alignment: .left)
            cell.textField?.lineBreakMode = .byTruncatingMiddle
            cell.toolTip = parent
        case "size":
            cell.configure(hit.size.map { Formatters.size.string(fromByteCount: $0) } ?? "—", alignment: .right)
            cell.textField?.lineBreakMode = .byTruncatingTail   // reset for cell reuse (may have been the path column last time)
            cell.toolTip = nil
        case "dateModified":
            cell.configure(hit.modified.map { Formatters.relativeDate($0) } ?? "—", alignment: .left)
            cell.textField?.lineBreakMode = .byTruncatingTail
            cell.toolTip = nil
        default:
            cell.configure("", alignment: .left)
        }
        return cell
    }
}
