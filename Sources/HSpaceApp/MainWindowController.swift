import AppKit
import HSpaceKernel
import BookmarkStore
import StashStore
import SessionStore
import Frecency
import TrashLedger

/// Main window (M17 custom deck): two continuous columns:
/// left sidebarColumn (full-height .sidebar material: traffic light row + stash shelf + bookmarks),
/// right contentColumn (TopDeckView deck + PaneGrid pane matrix + each pane's status bar).
/// Workspace tabs are self-managed (WorkspaceManager, native NSWindow tabbing abandoned); Tab cycles pane focus.
@MainActor
final class MainWindowController: NSWindowController, @preconcurrency NSMenuItemValidation {
    let kernel: OperationKernel
    let grid: PaneGridController
    let coordinator: FileOpsCoordinator
    let sidebar: SidebarViewController
    /// Stash shelf controller (M7): content persists through the StashStore pod, rows are shown in the sidebar
    let stashShelf: StashShelfController
    /// Custom top deck (M17): tab strip 28 + icon toolbar 36
    let deck = TopDeckView()
    /// Right-hand side panel: preview and inspector
    let detail = DetailPanelController()
    /// Workspace manager (M17): the window's [SessionWindow] + activeIndex; switch = snapshot current -> restore target
    private(set) var workspaces: WorkspaceManager!

    /// Manual NSSplitView (NSSplitViewController abandoned: its restore/resizing leaves required equality
    /// constraints on splitView that collapse the window under layout churn; the UI probe caught W==320/W==220/H==52 leaking)
    private let mainSplit = NSSplitView()
    let sidebarWrap = NSVisualEffectView()   // internal: the UISelfTest I-22 assertion must measure visibility
    /// Right column container: deck on top + pane matrix filling the rest (the only vertical divider is shared by this column and the left one)
    private let contentColumn = NSView()
    private var savedSidebarWidth: CGFloat = 200
    /// I-22: collapse state is fully self-managed. Never use NSSplitView's collapse mechanism: it keeps collapse in private state,
    /// and later layouts reapply isHidden (measured: width back to 202 but still hidden=true), so expanding always fails.
    private var sidebarCollapsedState = false
    private var keyMonitor: Any?
    /// Recent tab switcher (L30); does nothing until a shortcut starts it
    private(set) lazy var tabSwitcher = TabSwitcherController(host: self)

    init(kernel: OperationKernel, frecencyStore: FrecencyStore? = nil,
         trashLedger: TrashLedger? = nil,
         initialDirectory: URL, select: URL? = nil) {
        self.kernel = kernel
        self.grid = PaneGridController(initialDirectory: initialDirectory)
        self.coordinator = FileOpsCoordinator(kernel: kernel, grid: grid)
        self.coordinator.frecencyStore = frecencyStore   // M28: app-wide open/enter accounting
        self.coordinator.trashLedger = trashLedger       // "Put Back" ledger (same instance app-wide)
        let supportDir = AppDelegate.supportDirectory
        let model = SidebarModel(bookmarkStore: BookmarkStore(directory: supportDir))
        self.sidebar = SidebarViewController(model: model)
        self.stashShelf = StashShelfController(store: StashStore(directory: supportDir))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.minSize = NSSize(width: 600, height: 400)
        window.center()
        // M17: native window tabs abandoned (span the full window, conflicting with the continuous layout); workspaces are self-managed in WorkspaceManager
        window.tabbingMode = .disallowed
        // Custom deck: hidden title + transparent title bar + no NSToolbar (the I-10 tracking separator setup goes away with it)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar = nil
        // Window size/position is restored by the self-managed windowFrame key as the single authority (see setFrame below). macOS native window state restoration is off:
        // its savedState is invalidated by the system when the binary/signature changes (= a version update), and competing with our restore resets the size after updates
        // (root cause of a user report). With isRestorable=false only our restore applies, so the size deterministically survives version updates.
        window.isRestorable = false
        super.init(window: window)
        // Classic AppKit trap: the controller's default window cascading blocks setFrameAutosaveName restoration, so it must be turned off explicitly
        shouldCascadeWindows = false

        grid.coordinator = coordinator
        // Stash shelf wiring: batch copy/move is submitted through coordinator, and the "current pane" destination comes from grid
        stashShelf.coordinator = coordinator
        stashShelf.grid = grid
        sidebar.model.stash = stashShelf

        // Manual split: the sidebar material is wrapped in NSVisualEffectView; width/collapse are persisted by us
        mainSplit.isVertical = true
        mainSplit.dividerStyle = .thin
        mainSplit.delegate = self
        sidebarWrap.material = .sidebar
        sidebarWrap.blendingMode = .behindWindow
        let sv = sidebar.view
        sv.translatesAutoresizingMaskIntoConstraints = false
        sidebarWrap.addSubview(sv)
        NSLayoutConstraint.activate([
            sv.topAnchor.constraint(equalTo: sidebarWrap.topAnchor),
            sv.bottomAnchor.constraint(equalTo: sidebarWrap.bottomAnchor),
            sv.leadingAnchor.constraint(equalTo: sidebarWrap.leadingAnchor),
            sv.trailingAnchor.constraint(equalTo: sidebarWrap.trailingAnchor),
        ])

        // Right column = deck on top + pane matrix filling the rest
        deck.deckDelegate = self
        let gridView = grid.view
        gridView.translatesAutoresizingMaskIntoConstraints = false
        contentColumn.addSubview(deck)
        contentColumn.addSubview(gridView)
        let detailView = detail.view
        detailView.translatesAutoresizingMaskIntoConstraints = false
        contentColumn.addSubview(detailView)
        NSLayoutConstraint.activate([
            deck.topAnchor.constraint(equalTo: contentColumn.topAnchor),
            deck.leadingAnchor.constraint(equalTo: contentColumn.leadingAnchor),
            deck.trailingAnchor.constraint(equalTo: contentColumn.trailingAnchor),
            gridView.topAnchor.constraint(equalTo: deck.bottomAnchor),
            gridView.leadingAnchor.constraint(equalTo: contentColumn.leadingAnchor),
            gridView.trailingAnchor.constraint(equalTo: detailView.leadingAnchor),
            gridView.bottomAnchor.constraint(equalTo: contentColumn.bottomAnchor),
            detailView.topAnchor.constraint(equalTo: deck.bottomAnchor),
            detailView.trailingAnchor.constraint(equalTo: contentColumn.trailingAnchor),
            detailView.bottomAnchor.constraint(equalTo: contentColumn.bottomAnchor),
        ])

        for pane in [sidebarWrap, contentColumn] {
            pane.translatesAutoresizingMaskIntoConstraints = true
            pane.autoresizingMask = [.width, .height]
            mainSplit.addArrangedSubview(pane)
        }
        let host = NSViewController()
        host.view = NSView()
        host.addChild(sidebar)
        host.addChild(grid)
        host.addChild(detail)
        mainSplit.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(mainSplit)
        NSLayoutConstraint.activate([
            mainSplit.topAnchor.constraint(equalTo: host.view.topAnchor),
            mainSplit.bottomAnchor.constraint(equalTo: host.view.bottomAnchor),
            mainSplit.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            mainSplit.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
        ])
        window.contentViewController = host
        // Restore the self-managed frame, which must come **after** assigning contentViewController:
        // that assignment squeezes the window back to its content-fitted size (600×400 clamp), and restoring earlier would be overwritten
        // (the full root cause of the user's "size is not persisted"; autosave was dropped because it carries the system tiling tilingState)
        if let saved = UserDefaults.standard.string(forKey: Self.frameDefaultsKey) {
            let r = NSRectFromString(saved)
            if r.width >= 600, r.height >= 400 { window.setFrame(r, display: false) }
        }
        // Externalized default layout (applies to new windows/new workspaces; session restore overrides it)
        if let l = PaneLayout(rawValue: Preferences.defaultLayoutRaw), l != grid.layout {
            grid.apply(layout: l)
        }
        savedSidebarWidth = {
            let w = UserDefaults.standard.double(forKey: Self.sidebarWidthKey)
            return w > 0 ? min(max(w, 160), 320) : 200
        }()
        let startCollapsed = UserDefaults.standard.bool(forKey: "sidebarCollapsed")
        sidebarCollapsedState = startCollapsed
        deck.setSidebarCollapsed(startCollapsed)
        DispatchQueue.main.async { [weak self] in
            self?.applyColumnFrames()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(splitDidResize(_:)),
            name: NSSplitView.didResizeSubviewsNotification, object: mainSplit)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowFrameChanged(_:)),
            name: NSWindow.didEndLiveResizeNotification, object: window)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowFrameChanged(_:)),
            name: NSWindow.didMoveNotification, object: window)
        // Persist a final frame before closing (a terminate or window close may skip didEndLiveResize; prevents losing the last size)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowFrameChanged(_:)),
            name: NSWindow.willCloseNotification, object: window)

        sidebar.onNavigate = { [weak self] url in self?.grid.activePane.navigate(to: url) }
        detail.source = { [weak self] in
            guard let pane = self?.grid.activePane else { return nil }
            return DetailSource(directory: pane.activeTab.browser.current, selection: pane.currentSelectedItems(), pane: pane)
        }
        grid.onActiveLocationChange = { [weak self] url in
            self?.updateTitle(for: url)
            self?.detail.noteSelectionChanged()
            // The highlight follows the pane: the old sidebar highlight only showed "what was clicked last" and went on pointing at the old location after a directory change
            self?.sidebar.syncSelection(to: url)
            // I-47: persist on navigation (1s debounce); otherwise the location is saved only on clean exit, and an unclean exit (force quit/
            // Mac restart/crash) goes back to home. During restore sessionReady=false, so the noteStateChanged guard prevents self-overwrite.
            (NSApp.delegate as? AppDelegate)?.noteStateChanged()
        }
        grid.onActiveStatusChange = { [weak self] in
            guard let self else { return }
            self.deck.validateActions(hasSelection: self.grid.activePane.currentSelectionCount > 0)
            self.detail.noteSelectionChanged()
        }

        // Workspace manager: seed a single workspace from the current grid snapshot (grid.view has run loadView, pane pool in place)
        workspaces = WorkspaceManager(initial: grid.sessionWindow())
        updateTitle(for: initialDirectory)
        refreshWorkspaceTabs()
        // I-44: the item to select passed to openWindow(selecting:), located with view mode awareness (the select parameter used to be dropped outright,
        // so third-party "open file location" such as Antigravity reached the parent directory without selecting the file). The pending mechanism handles the first async directory read race.
        if let select { grid.activePane.reveal(select) }
        installKeyMonitor()
        ProblemAlert.show(ViewStylesHost.store.takeProblem())
        ProblemAlert.show(HiddenItems.store.takeProblem())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    func navigate(to url: URL) {
        grid.activePane.navigate(to: url)
    }

    // MARK: UISelfTest measurement entry (M17 §5: full-height divider / no drift on collapse)
    var sidebarColumnFrame: NSRect { sidebarWrap.frame }
    var contentColumnFrame: NSRect { contentColumn.frame }
    var workspaceCount: Int { workspaces.count }
    /// Self-test channel (I-73): workspace titles in order, to verify "an external open at the limit did not evict the oldest";
    /// counting alone is not enough (evicting the oldest then appending leaves the count unchanged).
    var uiTestWorkspaceTitles: [String] { workspaces.titles() }

    /// Called by AppDelegate on window close (the event monitor must be torn down explicitly)
    func teardown() {
        NotificationCenter.default.removeObserver(self)
        detail.teardown()
        tabSwitcher.cancel()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        sidebar.model.stop()
    }

    // MARK: Self-managed sidebar width persistence (replaces NSSplitView.autosaveName)

    /// Persist the frame (called at drag end/move/window close; not written in full screen)
    func persistFrameNow() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.frameDefaultsKey)
    }

    /// Frame persistence key: UITEST uses the isolated key `windowFrame.uitest`, never touching the user's real `windowFrame`.
    /// Test sandbox hard rule (I-46 user report "size resets after rebuild": the root cause was smoke SETFRAME writing the product key,
    /// so every smoke run overwrote the real window size with the test value 900×520).
    /// The same hard rule extends to sidebar width (I-46 only isolated the window frame; sidebar width still read the product key):
    /// in smoke, the I-37 narrow window assertion width = 511 - sidebarWidth, which drifted with the developer's real sidebar width,
    /// and with the sidebar dragged to the 320 limit the margin was used up and the assertion went red because of the environment.
    static var sidebarWidthKey: String {
        TestIsolation.defaultsKey("sidebarWidth")
    }

    static var frameDefaultsKey: String {
        TestIsolation.defaultsKey("windowFrame")
    }

    @objc private func splitDidResize(_ note: Notification) {
        let w = sidebarWrap.frame.width
        if w >= 160 {
            savedSidebarWidth = w
            UserDefaults.standard.set(w, forKey: Self.sidebarWidthKey)
            UserDefaults.standard.set(false, forKey: "sidebarCollapsed")
            deck.setSidebarCollapsed(false)
        } else if w < 1 {
            // Collapsed visuals (deck gives way to the traffic lights); collapse state is persisted only by toggleSidebar:
            // the momentary 0-width didResize at launch must never write collapsed=true (it would wrongly collapse on next launch)
            deck.setSidebarCollapsed(true)
        }
    }

    @objc private func windowFrameChanged(_ note: Notification) {
        persistFrameNow()
    }

    /// Self-implemented sidebar collapse (⌘⌥S / deck button): width 0 ⟷ remembered width; while collapsed the deck's leading edge gives way to the traffic lights
    @objc func toggleSidebar(_ sender: Any?) {
        setSidebar(collapsed: !sidebarCollapsedState)
    }

    /// Deterministic collapse/expand (deck button/menu reach this via toggle; UISelfTest specifies the target state directly).
    /// Self-managed widths set the frames directly (see the sidebarCollapsedState comment); subviews are never isHidden.
    func setSidebar(collapsed: Bool) {
        sidebarCollapsedState = collapsed
        sidebarWrap.isHidden = false
        applyColumnFrames()
        UserDefaults.standard.set(collapsed, forKey: "sidebarCollapsed")
        deck.setSidebarCollapsed(collapsed)
    }

    /// Set both column frames directly (shared by delegate resize and collapse toggling; collapsed = width 0, expanded = clamped remembered width)
    private func applyColumnFrames() {
        let divider = mainSplit.dividerThickness
        let w: CGFloat = sidebarCollapsedState ? 0 : min(max(savedSidebarWidth, 160), 320)
        sidebarWrap.frame = NSRect(x: 0, y: 0, width: w, height: mainSplit.bounds.height)
        contentColumn.frame = NSRect(x: w + (w > 0 ? divider : 0), y: 0,
                                     width: mainSplit.bounds.width - w - (w > 0 ? divider : 0),
                                     height: mainSplit.bounds.height)
        mainSplit.needsDisplay = true
        contentColumn.layoutSubtreeIfNeeded()
    }

    private func updateTitle(for url: URL) {
        // QSpace-style title: active directory | other visible pane directories
        let name: (URL) -> String = { $0.path == "/" ? "/" : $0.lastPathComponent }
        var parts = [name(url)]
        for pane in grid.visiblePanes where pane !== grid.activePane {
            parts.append(name(pane.activeTab.browser.current))
        }
        window?.title = parts.joined(separator: " | ")
        window?.representedURL = url
        syncDeck()
        refreshWorkspaceTabs()
        (NSApp.delegate as? AppDelegate)?.noteStateChanged()
    }

    /// Sync deck controls (fed back after active pane/location/layout/selection changes)
    func syncDeck() {
        let pane = grid.activePane
        let b = pane.activeTab.browser
        deck.syncViewMode(pane.activeTab.viewMode.rawValue)
        deck.syncLayout(grid.layout)
        deck.syncNav(canBack: b.canGoBack, canForward: b.canGoForward, canUp: b.canGoUp)
        deck.validateActions(hasSelection: pane.currentSelectionCount > 0)
    }

    /// Syncs the view switcher selection when the active pane/tab changes (old call sites kept)
    func syncViewModeControl() {
        deck.syncViewMode(grid.activePane.activeTab.viewMode.rawValue)
    }

    // MARK: Bookmarks (context menu "Add to Bookmarks" reaches here via the responder chain; each selected directory is added)

    @objc func addSelectionToBookmarks(_ sender: Any?) {
        let dirs = grid.activePane.activeTab.listVC.selectedItems
            .filter { $0.isDirectory && !$0.isPackage }
        guard !dirs.isEmpty else { NSSound.beep(); return }
        let store = sidebar.model.bookmarkStore
        Task { [weak self] in
            var added = 0
            var failure: (any Error)?
            for dir in dirs {
                do {
                    try await store.add(dir.url)
                    added += 1
                } catch {
                    failure = error
                }
            }
            self?.sidebar.model.rebuild()
            if let failure {
                Toast.show(failure.localizedDescription, in: self?.window)
            } else {
                Toast.show(String(format: L10n.t("toast.bookmarkAdded"), added), in: self?.window)
            }
        }
    }

    // MARK: Responder chain fallback (when the address bar's field editor has focus, actions cannot reach the pane/content VC; this is the end of the chain)

    /// ⌘R refresh. While the address bar is editing, firstResponder is the NSTextField's field editor, and in tests that chain reaches neither
    /// the three content VCs (the menu item targets #selector(FileListViewController.refresh(_:))) nor PaneViewController,
    /// so ⌘R became a dead key: the refresh half of the user's "after clearing the address bar, neither refresh nor going up recovers it" stuck here.
    /// NSWindow's nextResponder is the window controller, so this always gets it; just hand it to the active pane.
    @objc func refresh(_ sender: Any?) {
        grid.activePane.refresh(sender)
    }

    /// ⌘L go to path. Same as above: with the sidebar/address bar holding focus, no PaneViewController is on the chain and ⌘L would silently fail.
    @objc func editPath(_ sender: Any?) {
        grid.activePane.editPath(sender)
    }

    // MARK: Workspace tabs (M17: self-managed WorkspaceManager; ⌘T/⌘W/cycling + tab strip buttons all come here)

    /// Before switching, feed the grid's live snapshot into the active slot (otherwise the workspace being left loses unsaved edits)
    private func snapshotIntoActive() {
        workspaces.syncActive(grid.sessionWindow())
    }

    private func refreshWorkspaceTabs() {
        snapshotIntoActive()
        deck.updateWorkspaces(titles: workspaces.titles(), active: workspaces.activeIndex)
    }

    private func focusActivePane() {
        window?.makeFirstResponder(grid.activePane.focusTarget)
    }

    @objc func newWorkspaceTab(_ sender: Any?) {
        openWorkspaceTab(at: nil)
    }

    /// New workspace tab = **duplicate the current workspace**: same layout, each visible pane inherits its current
    /// path / sort / hidden state / view mode. A non-nil `directory` changes only the **active pane** to that directory
    /// (external opens take this route: since v0.19.26 they land on a workspace tab, no longer stuffing an invisible tab into a pane).
    ///
    /// With `allowEvictingOldest` false, at the workspace limit it **does not create a tab** and navigates the active pane in place instead:
    /// an external open comes from another app, and its "Reveal in Finder" should not evict the user's front-most workspace.
    ///
    /// The old ⌘T seeded one pane and copied only the path, with sort and the rest falling back to global default preferences (never set -> always Name);
    /// other panes were filled with stale pool content, hence "the right pane remembers Date Modified, the left one does not" (user report).
    func openWorkspaceTab(at directory: URL?, allowEvictingOldest: Bool = true) {
        snapshotIntoActive()
        let limit = Preferences.workspaceTabLimit
        if !allowEvictingOldest, limit > 0, workspaces.count >= limit {
            if let directory { grid.activePane.navigate(to: directory) }
            refreshWorkspaceTabs()
            focusActivePane()
            syncDeck()
            (NSApp.delegate as? AppDelegate)?.noteStateChanged()
            return
        }
        let current = grid.sessionWindow()
        let activeIndex = current.activePaneIndex
        // Build the snapshot from the panes' current state directly (rather than copying fields by hand): PaneGridController.restoreSession
        // skips rebuilds by "target state == current state", and if the two field lists drift apart that skip fails with nobody noticing.
        let fresh = SessionWindow(
            layoutRaw: current.layoutRaw,
            panes: grid.visiblePanes.enumerated().map { i, pane in
                var sp = pane.sessionPane()
                if i == activeIndex, let directory { sp.tab.path = directory.path }
                return sp
            },
            activePaneIndex: activeIndex)
        workspaces.append(fresh, limit: limit)
        grid.restoreSession(workspaces.activeState)
        refreshWorkspaceTabs()
        focusActivePane()
        syncDeck()
        (NSApp.delegate as? AppDelegate)?.noteStateChanged()
    }

    /// Window > Recent Tabs. Without a held shortcut it stays open until something is picked.
    @objc func showRecentTabs(_ sender: Any?) {
        tabSwitcher.start(backward: false, heldModifiers: [])
    }

    func switchWorkspace(to index: Int) {
        guard index != workspaces.activeIndex else { return }
        snapshotIntoActive()
        workspaces.switchTo(index)
        grid.restoreSession(workspaces.activeState)
        refreshWorkspaceTabs()
        focusActivePane()
        syncDeck()
        (NSApp.delegate as? AppDelegate)?.noteStateChanged()
    }

    func closeWorkspace(at index: Int) {
        snapshotIntoActive()
        let wasActive = index == workspaces.activeIndex
        if workspaces.close(at: index) {
            if wasActive { grid.restoreSession(workspaces.activeState) }
            refreshWorkspaceTabs()
            focusActivePane()
            syncDeck()
            (NSApp.delegate as? AppDelegate)?.noteStateChanged()
        } else {
            // Last workspace -> close the window (⌘W semantics)
            window?.performClose(nil)
        }
    }

    @objc func closeActiveWorkspace(_ sender: Any?) {
        closeWorkspace(at: workspaces.activeIndex)
    }

    /// ⌘1..9 direct access (I-13): menu item tag = workspace index; out of range is ignored by the switchTo guard
    @objc func switchWorkspaceByNumber(_ sender: NSMenuItem) {
        switchWorkspace(to: sender.tag)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if let enabled = BatchToolsMenu.validate(item, in: self) { return enabled }
        if let enabled = TemplateMenu.validate(item, in: self) { return enabled }
        if let enabled = DetailPanelMenu.validate(item, in: self) { return enabled }
        if let enabled = ViewStyleMenu.validate(item, in: self) { return enabled }
        if item.action == #selector(showRecentTabs(_:)) { return workspaces.count > 1 }
        if item.action == #selector(switchWorkspaceByNumber(_:)) {
            item.state = item.tag == workspaces.activeIndex ? .on : .off
            return item.tag < workspaces.count
        }
        return true
    }

    @objc func nextWorkspace(_ sender: Any?) { cycleWorkspace(backward: false) }
    @objc func previousWorkspace(_ sender: Any?) { cycleWorkspace(backward: true) }

    private func cycleWorkspace(backward: Bool) {
        guard workspaces.count > 1 else { return }
        snapshotIntoActive()
        workspaces.cycle(backward: backward)
        grid.restoreSession(workspaces.activeState)
        refreshWorkspaceTabs()
        focusActivePane()
        syncDeck()
        (NSApp.delegate as? AppDelegate)?.noteStateChanged()
    }

    /// AppDelegate session restore entry: rebuilds this window from a workspace array
    func restoreWorkspaces(_ ws: SessionWorkspaces) {
        guard !ws.workspaces.isEmpty else { return }
        workspaces = WorkspaceManager(states: ws.workspaces, activeIndex: ws.activeWorkspace)
        grid.restoreSession(workspaces.activeState)
        deck.updateWorkspaces(titles: workspaces.titles(), active: workspaces.activeIndex)
        syncDeck()
    }

    /// AppDelegate session save entry: feeds the active slot first, then hands over all workspaces
    func workspaceSnapshot() -> SessionWorkspaces {
        snapshotIntoActive()
        return SessionWorkspaces(workspaces: workspaces.states, activeWorkspace: workspaces.activeIndex)
    }

    // MARK: Tab cycles pane focus + ⌃⇥ cycles workspaces (passed through during text editing)

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, event.keyCode == 48,
                  !self.tabSwitcher.isActive else { return event }
            let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
            // The switcher takes the keyboard from here until its modifiers go up
            for (id, backward) in [("recentTabs", false), ("recentTabsBack", true)] {
                let binding = KeyBindings.binding(id)
                if binding.key == "\t", mods == binding.mods {
                    self.tabSwitcher.start(backward: backward, heldModifiers: binding.mods)
                    return nil
                }
            }
            // Workspace cycle modifiers come from the KeyBindings registry (cycleWorkspace/Back), no longer hard-coded ⌃/⌃⇧
            let fwd = KeyBindings.binding("cycleWorkspace")
            let back = KeyBindings.binding("cycleWorkspaceBack")
            if fwd.key == "\t", mods == fwd.mods { self.cycleWorkspace(backward: false); return nil }
            if back.key == "\t", mods == back.mods { self.cycleWorkspace(backward: true); return nil }
            if mods.isEmpty, !(self.window?.firstResponder is NSTextView) {
                self.grid.cycleFocus(backward: false)
                return nil
            }
            return event
        }
    }

    // MARK: Layout menu commands (shared by the deck segments and menu; syncs the deck selection)

    /// After a menu layout switch, sync the deck selection
    @objc func applyLayout(_ sender: NSMenuItem) {
        grid.applyLayout(sender)
        deck.syncLayout(grid.layout)
        (NSApp.delegate as? AppDelegate)?.noteStateChanged()
    }

    // MARK: Focused search (⌘F current folder / ⌥⌘F global)

    @objc func showSearchHere(_ sender: Any?) { showSearch(scopeGlobal: false) }
    @objc func showSearchGlobal(_ sender: Any?) { showSearch(scopeGlobal: true) }

    private func showSearch(scopeGlobal: Bool) {
        let dir = grid.activePane.activeTab.browser.current
        SearchPanelController.shared.show(scopeGlobal: scopeGlobal, currentDirectory: dir,
                                          attachedTo: window, onReveal: { [weak self] url in
            self?.revealSearchHit(url)
        }, onStash: { [weak self] urls in
            self?.stashShelf.add(urls)
        })
    }

    /// Enter to locate: directories (not packages) are entered directly; files/packages go to the parent with the item selected (reuses the prepareReveal reveal chain)
    func revealSearchHit(_ url: URL) {
        let pane = grid.activePane
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
        if exists, isDir.boolValue, !isPackage {
            pane.navigate(to: url)
        } else {
            pane.navigate(to: url.deletingLastPathComponent())
            pane.reveal(url)
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Deck action outlets (controls with selection state/validation)

extension MainWindowController: TopDeckDelegate {
    func deckToggleSidebar() { toggleSidebar(nil) }
    /// Clicking the trash button = navigate to the Trash **inside the app** (never handed off to Finder)
    func deckOpenTrash() { grid.activePane.goTrash(nil) }
    /// Right-clicking the trash button -> Empty Trash (picks the trash by the current pane's volume, same rule as opening/drops)
    func deckEmptyTrash() {
        coordinator.emptyTrash(at: TrashLocation.trash(for: grid.activePane.uiTestCurrentURL),
                               in: window)
    }
    /// Dragging onto the trash button = move to Trash (through the kernel; this layer has zero write APIs).
    /// Lands on the **source window's** coordinator: for cross-window drags the undo stack and toast belong to the initiating side,
    /// otherwise ⌘Z does nothing in the source window and the toast appears on a possibly covered window.
    func deckDropOnTrash(_ urls: [URL], from sourceWindow: NSWindow?) {
        let owner = (NSApp.delegate as? AppDelegate)?
            .mainWindowController(for: sourceWindow) ?? self
        owner.coordinator.moveToTrash(urls)
    }
    func deckGoBack() { grid.activePane.goBack(nil) }
    func deckGoForward() { grid.activePane.goForward(nil) }
    func deckGoUp() { grid.activePane.goUpFolder(nil) }
    func deckSetViewMode(_ mode: PaneViewMode) { grid.activePane.setViewMode(mode) }
    func deckSetLayout(_ layout: PaneLayout) {
        grid.apply(layout: layout)
        deck.syncLayout(grid.layout)
        (NSApp.delegate as? AppDelegate)?.noteStateChanged()
    }
    func deckNewWorkspace() { newWorkspaceTab(nil) }
    func deckSelectWorkspace(_ index: Int) { switchWorkspace(to: index) }
    func deckCloseWorkspace(_ index: Int) { closeWorkspace(at: index) }

    func deckHistory(forward: Bool) -> [URL] {
        let b = grid.activePane.activeTab.browser
        return forward ? b.forwardHistory : b.backHistory
    }

    func deckJumpHistory(forward: Bool, index: Int) {
        if forward { grid.activePane.jumpForwardHistory(to: index) }
        else { grid.activePane.jumpBackHistory(to: index) }
    }
}

// MARK: - Manual split constraints (min160/max320, collapsible to 0)

extension MainWindowController: @preconcurrency NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat { 160 }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat { 320 }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false   // I-22: collapse is self-managed (sidebarCollapsedState sets frames directly); AppKit's private collapse mechanism is disabled
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        // On window resize the sidebar keeps its width and the content takes the delta (Finder semantics); collapse comes from our own state
        applyColumnFrames()
    }
}
