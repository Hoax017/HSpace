import AppKit
import HSpaceContracts
import SessionStore
import ViewStyles

/// Pane content view mode (M9: independent per pane; ⌘1 icons / ⌘2 list / ⌘3 columns)
enum PaneViewMode: Int {
    case icons, list, columns
}

/// Pane: address bar (breadcrumbs ⟷ editor) + content view; one pane holds one browsing context (its own browser and history).
/// Multiple instances are arranged by PaneGridController; active pane highlighting is driven by setActive
@MainActor
final class PaneViewController: NSViewController {
    /// Browsing context = independent browse state + independent directory model + independent content views.
    /// Class semantics (M9): viewMode is mutable; icon/column views are created lazily, so there is no construction cost without switching.
    /// The three views share one DirectoryViewModel (onUpdate multicast); columns manage their own loading (local DirectoryReader)
    final class Tab {
        let browser: BrowserState
        let model: DirectoryViewModel
        let listVC: FileListViewController
        var viewMode: PaneViewMode = .list
        var iconVC: FileIconGridViewController?
        var columnVC: FileColumnViewController?
        /// The pane's own view options, while a folder rule has replaced them
        var styleBaseline: ViewStyle?
        /// What a folder rule says about the icon view, for an icon view not built yet
        var folderIconLayout: IconLayout?

        init(browser: BrowserState, model: DirectoryViewModel, listVC: FileListViewController) {
            self.browser = browser
            self.model = model
            self.listVC = listVC
        }
    }

    /// The single browsing context of this pane.
    ///
    /// Since v0.19.26 panes no longer have multiple tabs (M13's "multiple tabs per pane" was retired). Optional only to satisfy
    /// init order: the callbacks in `installTab` capture a fully initialized self; once installed it is never nil.
    private var tab: Tab?
    /// Current browsing context. The name `activeTab` is kept: tabs are gone but the meaning, "the context this pane is browsing",
    /// hasn't changed, and it spares edits to the two hundred or so call sites across the repository.
    var activeTab: Tab { tab! }

    /// Location change, passed up (window title)
    var onLocationChange: ((URL) -> Void)?
    /// User interaction in this pane → request to become the active pane
    var onRequestFocus: (() -> Void)?
    /// Count/selection change, passed up (the deck revalidates action button enabled state from it; M17)
    var onStatusChange: (() -> Void)?

    /// File-operation bridge: passed down to content views (context menus/shortcuts send OperationSpecs through it)
    var coordinator: FileOpsCoordinator? {
        didSet {
            guard let tab else { return }
            tab.listVC.coordinator = coordinator
            tab.iconVC?.coordinator = coordinator
            tab.columnVC?.coordinator = coordinator
        }
    }
    private let breadcrumb = BreadcrumbBar()
    /// "Empty" button: **shown only when the pane displays a Trash root**, like the one in native Finder.
    /// In the address bar's right end rather than the context menu; user report: hidden in the context menu, it might as well not exist.
    private let emptyTrashButton = NSButton()
    private let tagFilterPill = FilterPillButton()
    /// Button width slot (zero when hidden, so the breadcrumbs reclaim the width)
    private var emptyTrashWidth: NSLayoutConstraint!
    /// Breadcrumb trailing edge (leaves a 4pt gap while the button shows)
    private var breadcrumbTrailing: NSLayoutConstraint!
    private let pathEditor = PathEditorField()
    private let addressArea = AddressBarBacking()
    /// Inline address bar error hint (path missing/no permission): red text at the right end, fades after 1.5s; no alert (spec craftsmanship invariant)
    private let pathHint = NSTextField(labelWithString: "")
    private var pathHintFadeWorkItem: DispatchWorkItem?
    private let contentContainer = NSView()
    private let statusBar = StatusBarView()
    private(set) var isActivePane = false
    /// Pane-level suspension (set when the layout switches away): tab switches don't resume the watcher while set; north star of zero background power
    private(set) var isPaneSuspended = false

    init(directory: URL) {
        super.init(nibName: nil, bundle: nil)
        installTab(at: directory)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    override func loadView() {
        // onRequestFocus comes before the action: clicking an inactive pane's address bar in a multi-pane layout
        // used to navigate without activating, leaving the window title, deck button validation and status bar on the old pane
        // (list/icon/column views already report activity through onInteract; only the address bar was missing)
        breadcrumb.onNavigate = { [weak self] url in
            self?.onRequestFocus?()
            self?.navigate(to: url)
        }
        breadcrumb.onBeginEditing = { [weak self] in
            self?.onRequestFocus?()
            self?.beginPathEditing()
        }
        breadcrumb.onDropFiles = { [weak self] urls, target, forceCopy in
            // Dragging files onto a breadcrumb segment = dropping into that ancestor directory (same semantics as a list drop; the coordinator checks volumes and submits)
            self?.coordinator?.dropTransfer(urls: urls, into: target, forceCopy: forceCopy)
        }
        pathEditor.onCommit = { [weak self] url in
            self?.endPathEditing()
            self?.navigate(to: url)
        }
        pathEditor.onRevealFile = { [weak self] url in
            self?.endPathEditing()
            self?.revealFile(url)
        }
        pathEditor.onCancel = { [weak self] in self?.endPathEditing() }
        // Reset on focus loss: don't take focus (it's already where the user just clicked), just dismiss the editor so the breadcrumbs show again
        pathEditor.onReset = { [weak self] in self?.endPathEditing(takeFocus: false) }
        // Relative paths ("Downloads", "./x") resolve against the current browse directory; the process CWD means nothing to a file manager
        pathEditor.baseDirectory = { [weak self] in
            self?.activeTab.browser.current ?? FileManager.default.homeDirectoryForCurrentUser
        }
        pathEditor.onInvalid = { [weak self] message in self?.flashPathHint(message) }
        pathEditor.isHidden = true

        // Window-level key changes don't send didEndEditing (see the windowDidResignKey comment), so a notification has to close this gap.
        // object: nil + comparing view.window in the callback: panes change windows with layout rebuilds/session restore, so binding object would lose the link.
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification, object: nil)

        pathHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        pathHint.textColor = .systemRed
        pathHint.alignment = .right
        pathHint.lineBreakMode = .byTruncatingHead
        pathHint.drawsBackground = true                 // Covers the path text underneath, so short hints stay readable
        pathHint.backgroundColor = .controlBackgroundColor
        pathHint.isHidden = true

        // "Empty" button: added first, since the breadcrumb trailing edge hangs off its left
        emptyTrashButton.title = L10n.t("trash.empty.button")
        emptyTrashButton.bezelStyle = .rounded
        emptyTrashButton.controlSize = .small
        emptyTrashButton.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        emptyTrashButton.target = self
        emptyTrashButton.action = #selector(emptyTrashClicked(_:))
        emptyTrashButton.toolTip = L10n.t("trash.empty.tooltip")
        emptyTrashButton.isHidden = true
        emptyTrashButton.translatesAutoresizingMaskIntoConstraints = false
        addressArea.addSubview(emptyTrashButton)
        emptyTrashWidth = emptyTrashButton.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            emptyTrashWidth,
            emptyTrashButton.trailingAnchor.constraint(equalTo: addressArea.trailingAnchor, constant: -4),
            emptyTrashButton.centerYAnchor.constraint(equalTo: addressArea.centerYAnchor),
        ])

        for sub in [breadcrumb, pathEditor] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addressArea.addSubview(sub)
            NSLayoutConstraint.activate([
                sub.topAnchor.constraint(equalTo: addressArea.topAnchor, constant: 2),
                sub.bottomAnchor.constraint(equalTo: addressArea.bottomAnchor, constant: -2),
                sub.leadingAnchor.constraint(equalTo: addressArea.leadingAnchor, constant: 4),
            ])
        }
        // Breadcrumb trailing edge hangs off the left of the "Empty" button: at zero button width the edge lands where it used to (addressArea.trailing - 4),
        // so all of I-37's width math stays exactly the same while hidden.
        breadcrumbTrailing = breadcrumb.trailingAnchor.constraint(
            equalTo: emptyTrashButton.leadingAnchor, constant: 0)
        breadcrumbTrailing.isActive = true
        // The path editor still fills the whole row (the button collapses during editing and doesn't compete for space)
        pathEditor.trailingAnchor.constraint(equalTo: addressArea.trailingAnchor, constant: -4).isActive = true

        // Inline error hint floats at the right end of the address bar (added last = on top of the editor), without changing row height or squeezing the breadcrumbs
        pathHint.translatesAutoresizingMaskIntoConstraints = false
        addressArea.addSubview(pathHint)
        NSLayoutConstraint.activate([
            pathHint.centerYAnchor.constraint(equalTo: addressArea.centerYAnchor),
            pathHint.trailingAnchor.constraint(equalTo: addressArea.trailingAnchor, constant: -8),
            pathHint.leadingAnchor.constraint(greaterThanOrEqualTo: addressArea.leadingAnchor, constant: 8),
        ])

        let separator = NSBox()
        separator.boxType = .separator

        tagFilterPill.isHidden = true
        tagFilterPill.target = self
        tagFilterPill.action = #selector(clearTagFilter(_:))

        let root = NSView()
        root.wantsLayer = true
        for sub in [addressArea, separator, contentContainer, statusBar, tagFilterPill] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            // With fullSizeContentView, content extends under the title bar: top controls must anchor to the safeArea top
            // or the toolbar covers them (the address bar took over this top after the pane tab bar was retired)
            addressArea.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            addressArea.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            addressArea.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            addressArea.heightAnchor.constraint(equalToConstant: 24),
            separator.topAnchor.constraint(equalTo: addressArea.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: separator.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            tagFilterPill.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor, constant: -4),
            tagFilterPill.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -8),
            tagFilterPill.heightAnchor.constraint(equalToConstant: 20),
        ])
        view = root
        mountActiveTab()
        refreshChrome()
    }

    // MARK: Browsing context

    /// Installs this pane's browsing context (replacing any existing one, fully tearing down the old streams).
    @discardableResult
    private func installTab(at url: URL) -> Tab {
        if let old = tab {
            old.model.stopWatching()      // Switching context: leave no background watching
            quiesceContent(of: old)       // Cancel all in-flight tasks of the three views
            for vc in [old.listVC as NSViewController?, old.iconVC, old.columnVC].compactMap({ $0 }) {
                vc.view.removeFromSuperview()
                vc.removeFromParent()
            }
        }
        let browser = BrowserState(url: url)
        let model = DirectoryViewModel(directory: url)
        // Externalized default preferences: initialize from settings (hidden files/default sort key and direction/folders first/view mode)
        model.includeHidden = Preferences.showHiddenByDefault
        let defaultSortKey = SortSpec.Key(rawValue: Preferences.defaultSortKey) ?? .name
        model.sort = SortSpec(key: defaultSortKey, ascending: Preferences.defaultSortAscending,
                              foldersFirst: Preferences.foldersFirst)
        model.addOnUpdate { [weak self, weak model] in
            guard let self, self.tab?.model === model else { return }
            self.syncTagFilterPill()
        }
        model.onViewOptionsChange = { [weak self, weak model] in
            guard let self, self.tab?.model === model else { return }
            self.rememberViewChange()
        }
        let listVC = FileListViewController(model: model)
        listVC.coordinator = coordinator
        listVC.onNavigate = { [weak self] target in self?.navigate(to: target) }
        listVC.onNavigateBack = { [weak self] in self?.goBack(nil) }
        listVC.onInteract = { [weak self] in self?.onRequestFocus?() }
        // Status bar data source: snapshot applied/selection changed → refresh counts only if this context is still the current one
        listVC.onContentChange = { [weak self, weak listVC] in
            guard let self, self.activeTab.listVC === listVC else { return }
            self.updateStatusCounts()
        }
        listVC.onSelectionChange = { [weak self, weak listVC] in
            guard let self, self.activeTab.listVC === listVC else { return }
            self.updateStatusCounts()
        }
        let fresh = Tab(browser: browser, model: model, listVC: listVC)
        fresh.viewMode = PaneViewMode(rawValue: Preferences.defaultViewModeRaw) ?? .list
        tab = fresh
        return fresh
    }

    /// Lazily creates the icon grid view (shares one model; callback semantics match the list)
    private func ensureIconVC(for tab: Tab) -> FileIconGridViewController {
        if let vc = tab.iconVC { return vc }
        let vc = FileIconGridViewController(model: tab.model)
        vc.coordinator = coordinator
        vc.onNavigate = { [weak self] target in self?.navigate(to: target) }
        vc.onInteract = { [weak self] in self?.onRequestFocus?() }
        vc.onLayoutChange = { [weak self] in self?.rememberViewChange() }
        vc.setFolderLayout(tab.folderIconLayout)
        vc.onContentChange = { [weak self, weak tab] in
            guard let self, let tab, self.tab === tab else { return }
            self.updateStatusCounts()
        }
        vc.onSelectionChange = { [weak self, weak tab] in
            guard let self, let tab, self.tab === tab else { return }
            self.updateStatusCounts()
        }
        tab.iconVC = vc
        return vc
    }

    /// Lazily creates the column view (columns load themselves: local DirectoryReader; drill-down returns through onNavigate to sync this pane's address bar)
    private func ensureColumnVC(for tab: Tab) -> FileColumnViewController {
        if let vc = tab.columnVC { return vc }
        let vc = FileColumnViewController(model: tab.model)
        vc.coordinator = coordinator
        vc.onNavigate = { [weak self] target in self?.navigate(to: target) }
        vc.onInteract = { [weak self] in self?.onRequestFocus?() }
        vc.onSelectionChange = { [weak self, weak tab] in
            guard let self, let tab, self.tab === tab else { return }
            self.updateStatusCounts()
        }
        tab.columnVC = vc
        return vc
    }

    /// Content view controller for the current mode (icons/columns created on first use)
    private func contentVC(for tab: Tab) -> NSViewController {
        switch tab.viewMode {
        case .list: return tab.listVC
        case .icons: return ensureIconVC(for: tab)
        case .columns: return ensureColumnVC(for: tab)
        }
    }

    private func mountActiveTab() {
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        // Quiesce views not in the current mode (a view switched away leaves no in-flight tasks); north star of zero background power
        quiesceContent(of: activeTab, keep: activeTab.viewMode)
        let vc = contentVC(for: activeTab)
        if vc.parent !== self { addChild(vc) }
        let v = vc.view
        v.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(v)
        // Priority 999: a content view's (columns/grid) own size demands must never push out and change the window size (user-reported bug)
        let edges = [
            v.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            v.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
        ]
        for c in edges { c.priority = .init(999) }
        NSLayoutConstraint.activate(edges)
        // Don't resume if the pane itself was switched away by the layout (resumePane resumes it)
        if !isPaneSuspended {
            activeTab.model.resume()
            wakeActiveContent()
        }
    }

    /// Stops derived work of a tab's content views (decoration requests/column loads); the view of the `keep` mode is left running
    private func quiesceContent(of tab: Tab, keep: PaneViewMode? = nil) {
        if keep != .list { tab.listVC.cancelDecorationWork() }
        if keep != .icons { tab.iconVC?.cancelDecorationWork() }
        if keep != .columns { tab.columnVC?.suspend() }
    }

    /// Wakes the active tab's content view for its current mode (each mode's resume semantics)
    private func wakeActiveContent() {
        let tab = activeTab
        switch tab.viewMode {
        case .list: tab.listVC.refreshVisibleDecorations()
        case .icons: tab.iconVC?.refreshVisibleDecorations()
        case .columns: tab.columnVC?.wake(at: tab.browser.current)
        }
    }

    // MARK: Pane-level suspend/resume (called by PaneGridController on layout switches; north star of zero background power)

    /// Layout switches away from this pane: suspends the browsing context and cancels all decoration/column load requests
    func suspendPane() {
        guard !isPaneSuspended else { return }
        isPaneSuspended = true
        activeTab.model.suspend()
        quiesceContent(of: activeTab)
    }

    /// Layout switches back to this pane: resumes the browsing context's watcher and the current mode's view
    func resumePane() {
        guard isPaneSuspended else { return }
        isPaneSuspended = false
        activeTab.model.resume()
        wakeActiveContent()
    }

    private func refreshChrome() {
        // Any navigation/tab switch exits address bar editing, so the breadcrumbs show the current directory again.
        // Fixes the user-reported "refreshing/going up and back doesn't restore the address bar, it stays blank after clearing": these paths involve no focus loss,
        // so the focus-loss reset in controlTextDidEndEditing can't cover them, and editing must be forced closed where location is synced.
        // The isViewLoaded guard is essential: endPathEditing touches self.view, and refreshChrome can be reached from applyLocation
        // before the view loads (new window initialDirectory / external open reveal both take this path), when pathEditor.isHidden is still NSView's default false,
        // which would be misread as "editing" and force loadView early, disturbing the new window's creation and focus timing
        // (I-52, external open landing in the wrong window, reproduced deterministically from this). Same as the existing guard in restore(from:).
        if isViewLoaded, !pathEditor.isHidden { endPathEditing() }
        breadcrumb.setURL(activeTab.browser.current)
        syncEmptyTrashButton()
        onLocationChange?(activeTab.browser.current)
        applyActiveTint()
        // Status bar: counts refresh at once; volume capacity is read once per directory/tab change (read-only statfs, no polling)
        updateStatusCounts()
        statusBar.updateVolume(for: activeTab.browser.current)
    }

    /// While a tag filter hides items the pill says so, in every view mode, and one click ends it
    private func syncTagFilterPill() {
        let names = activeTab.model.tagFilter.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        tagFilterPill.title = L10n.f("tags.filter.pill", names.joined(separator: ", "))
        tagFilterPill.isHidden = names.isEmpty
    }

    @objc private func clearTagFilter(_ sender: Any?) {
        activeTab.model.setTagFilter([])
    }

    private func updateStatusCounts() {
        var items = activeTab.model.items.count
        var selected = 0
        var bytes: Int64 = 0
        switch activeTab.viewMode {
        case .list:
            let sel = activeTab.listVC.selectedItems
            selected = sel.count
            bytes = sel.reduce(0) { $0 + (activeTab.listVC.knownSize(of: $1) ?? 0) }
        case .icons:
            let sel = activeTab.iconVC?.selectedItems ?? []
            selected = sel.count
            bytes = sel.reduce(0) { $0 + ($1.size ?? 0) }
        case .columns:
            // Column semantics: count the focused column (columns load themselves, independent of model)
            if let vc = activeTab.columnVC {
                let counts = vc.statusCounts
                items = counts.items
                selected = counts.selected
                bytes = vc.selectedItems.reduce(0) { $0 + ($1.size ?? 0) }
            }
        }
        statusBar.update(itemCount: items, selectedCount: selected, selectedBytes: bytes)
        onStatusChange?()
    }

    /// Selection count of the current active content view (for deck action button validation)
    var currentSelectionCount: Int {
        switch activeTab.viewMode {
        case .list: return activeTab.listVC.selectedItems.count
        case .icons: return activeTab.iconVC?.selectedItems.count ?? 0
        case .columns: return activeTab.columnVC.map { $0.statusCounts.selected } ?? 0
        }
    }

    /// UISelfTest (M21): selects the first n items in list mode, refreshes counts, returns whether the status bar selection pill is visible
    func uiTestSelectFirstItemsAndPillVisible(_ n: Int) -> Bool {
        let urls = Array(activeTab.model.items.prefix(n)).map(\.url)
        activeTab.listVC.select(urls: urls)
        updateStatusCounts()
        return statusBar.selectionPillVisible
    }

    /// UISelfTest (I-30): programmatically enters path editing, exposing the editor to drive the first-key probe
    var uiTestPathEditor: PathEditorField { pathEditor }
    /// UISelfTest (I-37): exposes the breadcrumb address bar to drive truncation/folding/width-adaptive assertions
    var uiTestBreadcrumb: BreadcrumbBar { breadcrumb }
    /// I-30 probe: enters editing with a given seed (through the real begin chain, replacing only the seed text for a clean first-key assertion)
    func uiTestBeginPathEditing(seed: String) {
        beginPathEditing(with: seed)
    }

    /// UISelfTest (I-30 teardown): exits path editing and restores the breadcrumbs (a scenario must not leak edit state into later screenshots)
    func uiTestEndPathEditing() { endPathEditing() }

    /// UISelfTest (I-53): whether path editing is active (for focus-loss reset assertions)
    var uiTestIsPathEditing: Bool { !pathEditor.isHidden }

    /// UISelfTest (I-53): simulates "click elsewhere and lose focus" by moving firstResponder directly (not through onCancel)
    func uiTestBlurPathEditor() {
        view.window?.makeFirstResponder(focusTarget)
    }

    /// UISelfTest (I-53): current directory (what the address bar should reflect)
    var uiTestCurrentURL: URL { activeTab.browser.current }

    /// UISelfTest (I-53): current text of the address bar editor
    var uiTestPathEditorText: String { pathEditor.stringValue }

    /// UISelfTest (I-54): whether the inline error hint is showing / the text shown
    var uiTestPathHintVisible: Bool { !pathHint.isHidden && pathHint.alphaValue > 0 }
    var uiTestPathHintText: String { pathHint.stringValue }

    /// UISelfTest (I-54): the real entry point of ⌘R refresh (the responder chain reaches this controller first when the address bar has focus)
    func uiTestRefresh() { refresh(nil) }

    /// UISelfTest (I-55): whether the current tab shows hidden files (verifies auto-enabling when revealing a hidden file)
    var uiTestIncludeHidden: Bool { activeTab.model.includeHidden }

    /// UISelfTest (I-55): sets "show hidden files" on the current tab (for scenario cleanup, so it doesn't leak into later scenarios)
    func uiTestSetIncludeHidden(_ on: Bool) { activeTab.model.includeHidden = on }

    /// UISelfTest (I-58): the (key, ascending) currently shown by the column header sort indicator.
    /// The truth of "sort state lost" was the indicator not following model.sort: data sorted correctly while the arrow stayed on "Name",
    /// so the indicator and the model must be asserted separately; checking only model.sort would miss this bug.
    var uiTestSortIndicator: (key: String, ascending: Bool)? {
        guard let d = activeTab.listVC.tableView.sortDescriptors.first, let k = d.key else { return nil }
        return (k, d.ascending)
    }

    /// UISelfTest (I-59): goes through each view's real copyPath(_:) (the empty-space shortcut path), no shortcuts
    func uiTestCopyPath(to pasteboard: NSPasteboard) {
        switch activeTab.viewMode {
        case .list:    activeTab.listVC.copyPath(to: pasteboard)
        case .icons:   activeTab.iconVC?.copyPath(to: pasteboard)
        case .columns: activeTab.columnVC?.copyPath(to: pasteboard)
        }
    }

    /// UISelfTest (I-59): the current directory **as the view sees it** (source of truth for copyPath's fallback with no selection).
    /// In column view currentDirectory comes from the focused column and lags browser.current during async chain building;
    /// assertions must watch this value, since watching browser.current would pass before the column chain is in place.
    var uiTestViewCurrentDirectory: URL {
        switch activeTab.viewMode {
        case .list:    return activeTab.listVC.currentDirectory
        case .icons:   return activeTab.iconVC?.currentDirectory ?? activeTab.browser.current
        case .columns: return activeTab.columnVC?.currentDirectory ?? activeTab.browser.current
        }
    }

    /// UISelfTest (I-59): clears the current view's selection (simulates "clicking empty space in a folder")
    func uiTestClearSelection() {
        switch activeTab.viewMode {
        case .list:    activeTab.listVC.tableView.deselectAll(nil)
        case .icons:   activeTab.iconVC?.uiTestClearSelection()
        case .columns: activeTab.columnVC?.uiTestSelectInFocusedColumn([])
        }
    }

    /// UISelfTest (I-58): changes the model sort directly (simulates the session restore path; restore writes it this way, bypassing column headers)
    func uiTestSetSort(key: String, ascending: Bool) {
        guard let k = SortSpec.Key(rawValue: key) else { return }
        activeTab.model.sort = SortSpec(key: k, ascending: ascending,
                                        foldersFirst: activeTab.model.sort.foldersFirst)
    }

    /// UISelfTest (I-58): model-side sort (control group)
    var uiTestModelSort: (key: String, ascending: Bool) {
        (activeTab.model.sort.key.rawValue, activeTab.model.sort.ascending)
    }

    /// UISelfTest (I-57): the directory the breadcrumbs currently show / whether visible.
    /// "Breadcrumbs shown again" must verify content: an assertion on !isHidden alone stays green even with breadcrumb.isHidden=false deleted.
    var uiTestBreadcrumbURL: URL { breadcrumb.url }
    var uiTestBreadcrumbVisible: Bool { !breadcrumb.isHidden }

    /// UISelfTest (I-57): whether the address bar still holds the field editor (it must be released after exiting editing;
    /// "isHidden=true but field editor still present" is a reachable state that checking isHidden alone can't cover)
    var uiTestPathEditorHasFocus: Bool { pathEditor.currentEditor() != nil }

    /// UISelfTest (I-32): refreshes status bar counts and returns whether the selection pill is visible (selection cleared after delete → no "selected" pill)
    func uiTestRefreshAndSelectionPillVisible() -> Bool {
        updateStatusCounts()
        return statusBar.selectionPillVisible
    }

    // MARK: Navigation (single entry point: history/address bar/content stay in sync)

    func navigate(to url: URL) {
        coordinator?.recordAccess(url)   // M28: entering a folder = one usage record (for search ranking by usage)
        activeTab.browser.navigate(to: url)
        applyLocation()
    }

    private func applyLocation() {
        let styledMode = prepareFolderStyle(for: activeTab.browser.current)
        activeTab.model.navigate(to: activeTab.browser.current)
        finishFolderStyle(styledMode)
        // Column mode: keep the column chain in step (drill-down along the chain extends in place; a jump rebuilds the chain)
        if activeTab.viewMode == .columns {
            activeTab.columnVC?.showDirectory(activeTab.browser.current)
        }
        refreshChrome()
    }

    // MARK: View mode switching (M9: ⌘1 icons / ⌘2 list / ⌘3 columns; selection carried over by URL set)

    func setViewMode(_ mode: PaneViewMode, takeFocus: Bool = true) {
        guard activeTab.viewMode != mode else { return }
        let carried = currentSelectionURLs()
        // Switching view mode mid-read: the pending reveal is still on the old view; unless moved it is lost for good,
        // and left in the old view as a time bomb that later "ghost-selects" and steals focus. Take it first, then attach it to the new view.
        let carriedReveal = takePendingReveal()
        activeTab.viewMode = mode
        mountActiveTab()
        restoreSelection(carried)
        if let carriedReveal { revealAfterLoad(carriedReveal.url, rename: carriedReveal.rename) }
        if takeFocus { view.window?.makeFirstResponder(focusTarget) }
        updateStatusCounts()
        rememberViewChange()
    }

    /// Takes the pending reveal from the current view (for relocation on view mode switch)
    private func takePendingReveal() -> (url: URL, rename: Bool)? {
        switch activeTab.viewMode {
        case .list:  return activeTab.listVC.takePendingReveal()
        case .icons: return activeTab.iconVC?.takePendingReveal()
        case .columns:
            guard let url = activeTab.columnVC?.takePendingReveal() else { return nil }
            return (url, false)   // Columns have no inline rename semantics
        }
    }

    private func currentSelectionURLs() -> [URL] {
        switch activeTab.viewMode {
        case .list: return activeTab.listVC.selectedURLs
        case .icons: return activeTab.iconVC?.selectedURLs ?? []
        case .columns: return activeTab.columnVC?.selectedURLs ?? []
        }
    }

    private func restoreSelection(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        switch activeTab.viewMode {
        case .list: activeTab.listVC.select(urls: urls)
        case .icons: activeTab.iconVC?.select(urls: urls)
        case .columns: activeTab.columnVC?.select(urls: urls)
        }
    }

    // MARK: Session snapshot/restore (M11; SessionStore contract)

    func sessionPane() -> SessionPane {
        SessionPane(tab: SessionTab(path: activeTab.browser.current.path,
                                    sortKey: activeTab.model.sort.key.rawValue,
                                    sortAscending: activeTab.model.sort.ascending,
                                    includeHidden: activeTab.model.includeHidden,
                                    viewMode: activeTab.viewMode.rawValue))
    }

    /// Rebuilds the browsing context from a snapshot (a vanished path falls back to the home directory, per the fault-tolerance matrix)
    func restoreSession(_ pane: SessionPane) {
        let fm = FileManager.default
        let st = pane.tab
        var isDir: ObjCBool = false
        let url = (fm.fileExists(atPath: st.path, isDirectory: &isDir) && isDir.boolValue)
            ? URL(fileURLWithPath: st.path)
            : fm.homeDirectoryForCurrentUser
        let fresh = installTab(at: url)
        if let key = SortSpec.Key(rawValue: st.sortKey) {
            fresh.model.sort = SortSpec(key: key, ascending: st.sortAscending,
                                        foldersFirst: fresh.model.sort.foldersFirst)
        }
        fresh.model.includeHidden = st.includeHidden
        if let raw = st.viewMode, let vm = PaneViewMode(rawValue: raw) {
            fresh.viewMode = vm
        }
        // The snapshot holds what the rule gave; what comes back on leaving the folder is the default
        if ViewStylesHost.store.rule(for: url.path) != nil { fresh.styleBaseline = Self.defaultStyle }
        if isViewLoaded {
            mountActiveTab()
            refreshChrome()
        }
    }

    // MARK: Active pane highlight / inactive pane dimming

    /// Dimming overlay for inactive pane content (lazily built; alpha = preference value, hidden at 0 or when active)
    private var dimOverlay: NSView?

    func setActive(_ active: Bool, dimmed: Bool = false) {
        isActivePane = active
        applyActiveTint()
        // Inactive pane dimming (QSpace appearance option): a translucent black overlay over contentContainer;
        // dimmed is passed by the grid (true only for inactive panes in multi-pane layouts); a single pane is never dimmed
        let alpha = Preferences.inactivePaneDimming
        if dimmed, alpha > 0 {
            let overlay = ensureDimOverlay()
            overlay.frame = contentContainer.bounds
            overlay.layer?.opacity = Float(alpha)
            overlay.isHidden = false
            contentContainer.addSubview(overlay)   // Placed above the content (remounted after mountActiveTab clears)
        } else {
            dimOverlay?.isHidden = true
        }
    }

    /// Lazily builds the dimming overlay (autoresizes with contentContainer; no constraints, so it survives content view remounts)
    private func ensureDimOverlay() -> NSView {
        if let overlay = dimOverlay { return overlay }
        let overlay = NSView()
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.black.cgColor
        overlay.frame = contentContainer.bounds
        overlay.autoresizingMask = [.width, .height]
        dimOverlay = overlay
        return overlay
    }

    private func applyActiveTint() {
        // No tint when the highlight preference is off; accent goes through Theme.accent (customizable theme color).
        // Background resolution is left to AddressBarBacking.updateLayer (appearance-aware, re-resolved on light/dark switches).
        addressArea.highlighted = isActivePane && Preferences.activePaneHighlight
    }

    /// Focus target (PaneGrid hands keyboard focus to the content view when activating a pane)
    var focusTarget: NSView {
        switch activeTab.viewMode {
        case .list: return activeTab.listVC.focusTarget
        case .icons: return ensureIconVC(for: activeTab).focusTarget
        case .columns: return ensureColumnVC(for: activeTab).focusTarget
        }
    }

    /// Re-reads active content after an operation (real FS projection refresh; columns also refresh their own chain)
    func reloadActiveList() {
        activeTab.model.reload()
        if activeTab.viewMode == .columns { activeTab.columnVC?.reloadAllColumns() }
    }

    /// Redraws active content only (cut dimming changed; no need to re-read the disk)
    func redrawActiveList() {
        switch activeTab.viewMode {
        case .list: activeTab.listVC.redraw()
        case .icons: activeTab.iconVC?.redraw()
        case .columns: activeTab.columnVC?.redraw()
        }
    }

    // MARK: Address bar editing

    func beginPathEditing() {
        beginPathEditing(with: activeTab.browser.current.path)
    }

    private func beginPathEditing(with seed: String) {
        onRequestFocus?()
        pathEditor.isHidden = false
        breadcrumb.isHidden = true
        syncEmptyTrashButton()
        hidePathHint()
        pathEditor.beginEditing(with: seed)
    }

    private func endPathEditing(takeFocus: Bool = true) {
        pathEditor.isHidden = true
        breadcrumb.isHidden = false
        syncEmptyTrashButton()
        hidePathHint()
        // takeFocus=false on the focus-loss reset path: focus is already elsewhere (perhaps another pane, the sidebar, the toolbar),
        // and makeFirstResponder would snatch back the focus the user just moved: they click the next pane and the cursor jumps back here.
        if takeFocus { view.window?.makeFirstResponder(focusTarget) }
    }

    /// In-place feedback for an invalid path: red text at the right end of the address bar, fading after 1.5s (no alert; spec craftsmanship invariant)
    private func flashPathHint(_ message: String) {        pathHintFadeWorkItem?.cancel()
        pathHint.stringValue = message
        pathHint.alphaValue = 1
        pathHint.isHidden = false
        // VoiceOver announcement: otherwise visually impaired users hear only a beep and have no idea what went wrong
        NSAccessibility.post(element: pathHint, notification: .announcementRequested,
                             userInfo: [.announcement: message,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
        let fade = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                self.pathHint.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                self?.pathHint.isHidden = true
            }
        }
        pathHintFadeWorkItem = fade
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: fade)
    }

    private func hidePathHint() {
        pathHintFadeWorkItem?.cancel()
        pathHintFadeWorkItem = nil
        pathHint.isHidden = true
    }

    /// When the window loses key (opening Settings / the ⌘F search panel / ⌘Tab to another app), **AppKit does not send**
    /// `controlTextDidEndEditing`. Measured with a standalone probe: after resignKey the field editor is still there and
    /// pathEditor.isHidden is still false. So the focus-loss reset path never notices: a user clears the address bar,
    /// opens Settings, and comes back to a blank input box covering the breadcrumbs.
    ///
    /// **Dismiss only when the text is empty**: ⌘L select-all, switching to Finder/Terminal to copy a path, then back for ⌘V
    /// is the top use case served here. An unconditional reset would close the editor and return focus to the file list, so that ⌘V would hit
    /// the list's pasteItems and become "paste files into the current directory", escalating a pure browsing action into a disk write.
    /// Empty text means the user has nothing pending to lose, so dismissing is pure gain.
    @objc private func windowDidResignKey(_ note: Notification) {
        guard isViewLoaded, (note.object as? NSWindow) === view.window,
              !pathEditor.isHidden,
              pathEditor.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        endPathEditing(takeFocus: false)   // The window is losing key; don't grab focus
    }

    /// Pasted file path (.apk etc) or package path (.app): enters its parent and selects the item (Finder semantics)
    private func revealFile(_ fileURL: URL) {
        // The target is hidden and hidden files aren't showing: the user **named this file explicitly**.
        // Without turning them on we'd jump to the parent and select nothing, which to the user looks like "Return did nothing".
        // Turn on hidden files for this pane (per pane, ⌘⇧. turns it off any time) so the user really sees what they asked for.
        if Self.isHiddenItem(fileURL), !activeTab.model.includeHidden {
            // Not a view change of the folder being left, so no rule takes it up
            activeTab.model.setViewOptions(sort: activeTab.model.sort, includeHidden: true)
        }
        let parent = fileURL.deletingLastPathComponent()
        navigate(to: parent)
        revealAfterLoad(fileURL)
    }

    /// Whether this is a hidden item: dot prefix, or the macOS hidden flag (the latter is UF_HIDDEN, which the dot prefix doesn't cover)
    private static func isHiddenItem(_ url: URL) -> Bool {
        if url.lastPathComponent.hasPrefix(".") { return true }
        return (try? url.resourceValues(forKeys: [.isHiddenKey]))?.isHidden ?? false
    }

    // MARK: Menu commands (responder chain, active pane only)

    @objc func goBack(_ sender: Any?) {
        if activeTab.browser.goBack() != nil { applyLocation() }
    }

    @objc func goForward(_ sender: Any?) {
        if activeTab.browser.goForward() != nil { applyLocation() }
    }

    /// I-39: after ⌘↑ goes up, auto-select the child directory we came from (Finder/QSpace semantics); the first half of the round trip with ⌘↓
    @objc func goUpFolder(_ sender: Any?) {
        let child = activeTab.browser.current
        if activeTab.browser.goUp() != nil {
            applyLocation()
            revealAfterLoad(child)
        }
    }

    /// I-39: ⌘↓ goes down: a single selected folder enters in the pane; other selections go to the view's open logic (files to the default app);
    /// with no selection, returns to the most recent history entry if it's a direct child (the just-⌘↑-ed case, without growing history)
    @objc func goDownFolder(_ sender: Any?) {
        let items = currentSelectedItems()
        if items.count == 1, let only = items.first, only.isDirectory, !only.isPackage {
            navigate(to: only.url)
            return
        }
        if !items.isEmpty {
            switch activeTab.viewMode {
            case .list: activeTab.listVC.openSelected(nil)
            case .icons: activeTab.iconVC?.openSelected(nil)
            case .columns: activeTab.columnVC?.openSelected(nil)
            }
            return
        }
        if canDescendIntoHistory, activeTab.browser.goBack() != nil { applyLocation() }
    }

    /// Whether the most recent back-history entry is a direct child of the current directory (shared by the ⌘↓ no-selection fallback and menu validation)
    private var canDescendIntoHistory: Bool {
        guard let recent = activeTab.browser.backHistory.first else { return false }
        return recent.deletingLastPathComponent().standardizedFileURL.path
            == activeTab.browser.current.standardizedFileURL.path
    }

    func currentSelectedItems() -> [FileItem] {
        switch activeTab.viewMode {
        case .list: return activeTab.listVC.selectedItems
        case .icons: return activeTab.iconVC?.selectedItems ?? []
        case .columns: return activeTab.columnVC?.selectedItems ?? []
        }
    }

    /// Runs a selection command on the active content view, the one that owns the selection
    func performContentAction(_ selector: Selector, from sender: Any?) {
        onRequestFocus?()
        NSApp.sendAction(selector, to: contentVC(for: activeTab), from: sender)
    }

    /// Whether the active content view would accept the command now, by the same rules as its menus
    func canPerformContentAction(_ selector: Selector) -> Bool {
        guard !currentSelectedItems().isEmpty else { return false }
        let probe = NSMenuItem(title: "", action: selector, keyEquivalent: "")
        return (contentVC(for: activeTab) as? NSMenuItemValidation)?.validateMenuItem(probe) ?? true
    }

    /// Selects the given entry once navigation lands (each view has its own "select after load" mechanism, avoiding the async directory read race)
    private func revealAfterLoad(_ url: URL, rename: Bool = false) {
        switch activeTab.viewMode {
        case .list: activeTab.listVC.prepareReveal(url, rename: rename)
        case .icons: activeTab.iconVC?.prepareReveal(url, rename: rename)
        case .columns: activeTab.columnVC?.select(urls: [url])
        }
    }

    /// Public view-mode-aware reveal entry (shared by external reveal / open-in-HSpace / search reveal / open-new-window select):
    /// set the directory first, then call this; each view's pending mechanism applies the selection after the async read finishes (I-44).
    func reveal(_ url: URL) { revealAfterLoad(url) }

    /// Selects exactly these items of the shown folder; none clears the selection (AppleScript, L62)
    func selectItems(_ urls: [URL]) {
        switch activeTab.viewMode {
        case .list: activeTab.listVC.select(urls: urls)
        case .icons: activeTab.iconVC?.select(urls: urls)
        case .columns: activeTab.columnVC?.select(urls: urls)
        }
        updateStatusCounts()
    }

    /// Navigation history (for the long-press history menu): most recent first
    var backHistory: [URL] { activeTab.browser.backHistory }
    var forwardHistory: [URL] { activeTab.browser.forwardHistory }

    /// Jumps to back/forward history item `index` (0 = most recent)
    func jumpBackHistory(to index: Int) {
        if activeTab.browser.jumpBack(to: index) != nil { applyLocation() }
    }

    func jumpForwardHistory(to index: Int) {
        if activeTab.browser.jumpForward(to: index) != nil { applyLocation() }
    }

    @objc func editPath(_ sender: Any?) {
        beginPathEditing()
    }

    /// ⌘R refresh: the responder chain reaches this controller first when the address bar has focus (with content focused, each view VC's own refresh handles it).
    /// User report: "refreshing doesn't restore the address bar after clearing it". Refresh involves neither focus loss nor navigation, so neither existing reset path covers it;
    /// editing must be closed explicitly here, or the blank editor stays on top of the breadcrumbs.
    @objc func refresh(_ sender: Any?) {
        if isViewLoaded, !pathEditor.isHidden { endPathEditing() }
        reloadActiveList()
    }

    /// Visibility of the "Empty" button: shown only at a **Trash root** and while not editing the address.
    /// Width goes to zero rather than just isHidden: hidden views still take Auto Layout space,
    /// and hiding alone would needlessly cost the breadcrumbs some width.
    private func syncEmptyTrashButton() {
        guard isViewLoaded else { return }
        let show = TrashLocation.isTrashRoot(activeTab.browser.current) && pathEditor.isHidden
        emptyTrashButton.isHidden = !show
        emptyTrashWidth.constant = show ? emptyTrashButton.intrinsicContentSize.width : 0
        breadcrumbTrailing.constant = show ? -4 : 0
        addressArea.needsLayout = true
    }

    @objc private func emptyTrashClicked(_ sender: Any?) {
        let here = activeTab.browser.current
        guard TrashLocation.isTrashRoot(here) else { return }
        onRequestFocus?()
        coordinator?.emptyTrash(at: here, in: view.window)
    }

    /// List bottom margin (I-65): reads the real scrollView's contentInsets, without copying the constant
    var uiTestListBottomInset: CGFloat { activeTab.listVC.uiTestBottomInset }
    /// Empty-space context menu (through the callback actually injected into BlankAreaScrollView)
    func uiTestBlankAreaMenu() -> NSMenu? { activeTab.listVC.uiTestBlankAreaMenu() }

    // ---- Self-test channel (I-64) ----
    var uiTestEmptyTrashButtonVisible: Bool { isViewLoaded && !emptyTrashButton.isHidden }
    var uiTestEmptyTrashButtonWidth: CGFloat { emptyTrashWidth?.constant ?? -1 }
    var uiTestEmptyTrashButtonTitle: String { emptyTrashButton.title }
    /// Goes through the button's real action (no copy); returns whether it was really clickable
    func uiTestClickEmptyTrashButton() -> Bool {
        guard !emptyTrashButton.isHiddenOrHasHiddenAncestor, emptyTrashButton.isEnabled,
              emptyTrashButton.action != nil, emptyTrashButton.target != nil else { return false }
        emptyTrashButton.performClick(nil)
        return true
    }

    /// Go to the Trash (the deck trash button and the Go menu share this exit)
    @objc func goTrash(_ sender: Any?) {
        // Picks the Trash of the **current volume**: browsing an external disk jumps to that volume's trash,
        // matching where fm.trashItem actually puts things (otherwise the button points somewhere other than where files go)
        navigate(to: TrashLocation.trash(for: activeTab.browser.current))
    }

    @objc func goHome(_ sender: Any?) {
        navigate(to: FileManager.default.homeDirectoryForCurrentUser)
    }


    // View mode menu (View > as Icons/as List/as Columns)
    @objc func viewAsIcons(_ sender: Any?) { setViewMode(.icons) }
    @objc func viewAsList(_ sender: Any?) { setViewMode(.list) }
    @objc func viewAsColumns(_ sender: Any?) { setViewMode(.columns) }
}

/// Address bar backing (appearance-aware): opaque controlBackgroundColor base normally, accent 0.10 layered on for the active pane.
/// Key point: updateLayer instead of a one-off cgColor, so system light/dark switches and .hspaceThemeChanged re-resolve automatically,
/// avoiding inactive address bars rendering as white blocks in dark mode / stale caches (the old one-off cgColor was read in light mode and never refreshed in dark).
private final class AddressBarBacking: NSView {
    var highlighted = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let base = NSColor.controlBackgroundColor
            let bg = highlighted ? (base.blended(withFraction: 0.10, of: Theme.accent) ?? base) : base
            layer?.backgroundColor = bg.cgColor
        }
    }
}

extension PaneViewController: @preconcurrency NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBack(_:)): return activeTab.browser.canGoBack
        case #selector(goForward(_:)): return activeTab.browser.canGoForward
        case #selector(goUpFolder(_:)): return activeTab.browser.canGoUp
        case #selector(goDownFolder(_:)): return currentSelectionCount > 0 || canDescendIntoHistory
        case #selector(viewAsIcons(_:)):
            menuItem.state = activeTab.viewMode == .icons ? .on : .off
            return true
        case #selector(viewAsList(_:)):
            menuItem.state = activeTab.viewMode == .list ? .on : .off
            return true
        case #selector(viewAsColumns(_:)):
            menuItem.state = activeTab.viewMode == .columns ? .on : .off
            return true
        default: return true
        }
    }
}
