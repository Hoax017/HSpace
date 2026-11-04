import AppKit

// Direction contract, copied from the top of docs/design/M17-deck-spec.md (the sole authority)
// THESIS: take the native macOS professional tool standard to the limit: Finder's material language × QSpace's density and topology;
//        character comes from structure and craft, not color (the user vetoed all "fancy web color schemes"; the seed f8a2afe5 dice roll was superseded by the user's canon outlet).
// OWN-WORLD: the existing theme system (Theme.accent / appearanceMode / accentColorHex) + system materials
//        (NSVisualEffectView .titlebar/.sidebar) + SF Symbols + hairline separators + 4pt grid. Strip all content
//        and the topology still identifies it: one full-height divider, the stash pile on top of the left column, a three-layer deck in the right column.
// STORY: open it and four things can be scanned on one screen: which pane has focus, where the path is, what is in the stash shelf, how far tasks have run.
// FIRST VIEWPORT: left column = traffic light row(28) + stash shelf(148) + bookmarks/iCloud/locations; right column = workspace tab strip(28)
//        + icon toolbar(36) + pane matrix(each pane has its own address bar) + status bar(22).
// FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review,
//        the verdict, and DESIGN.md.

/// Deck action outlets (implemented by MainWindowController): controls that need selection state/validation go through this protocol;
/// pure responder chain actions (AirDrop/terminal) are sent up by the deck directly with target=nil to the first responder.
/// The trash button is not in the responder chain group: it has two intents (click = open, drop = move in), both through this protocol.
@MainActor
protocol TopDeckDelegate: AnyObject {
    /// Clicking the trash button = **open the Trash** (always available, regardless of selection)
    func deckOpenTrash()
    /// Right-clicking the trash button = Empty Trash (**irreversible**, the outlet brings its own confirmation alert)
    func deckEmptyTrash()
    /// Dragging files onto the trash button = move to Trash (the old "button = delete" semantics are kept here, not lost).
    /// `sourceWindow` = the window that started the drag: for cross-window drags undo and toast must belong to it,
    /// otherwise ⌘Z does nothing in the source window and the toast appears on a possibly covered window.
    func deckDropOnTrash(_ urls: [URL], from sourceWindow: NSWindow?)
    func deckToggleSidebar()
    func deckGoBack()
    func deckGoForward()
    func deckGoUp()
    func deckSetViewMode(_ mode: PaneViewMode)
    func deckSetLayout(_ layout: PaneLayout)
    func deckNewWorkspace()
    func deckSelectWorkspace(_ index: Int)
    func deckCloseWorkspace(_ index: Int)
    /// Navigation history (popped up by long-pressing the back/forward segment; most recent first)
    func deckHistory(forward: Bool) -> [URL]
    func deckJumpHistory(forward: Bool, index: Int)
}

/// Custom top deck (M17 §1/§3/§6.2): two rows inside NSVisualEffectView(.titlebar):
/// workspace tab strip(28) + hairline + icon toolbar(36) + hairline. Density matches QSpace (buttons 24×24 / SF13 / spacing 4).
/// Toolbar A1 left/right split: left = sidebar│navigation│view segments (near the content), flexible space doubling as a window drag handle, right = actions│five layout segments.
/// Blank deck space drags the window; double-click zooms/minimizes per system AppleActionOnDoubleClick. No new colors (Theme.accent/system semantic colors/materials).
@MainActor
final class TopDeckView: NSVisualEffectView {
    static let tabRowHeight: CGFloat = 40
    static let toolbarRowHeight: CGFloat = 36
    /// With the sidebar collapsed the traffic lights sit at the deck's top left, so the tab row gives way (collapsed state only; §1, rounded to the 4pt scale = 80)
    static let trafficLightInset: CGFloat = 80

    weak var deckDelegate: TopDeckDelegate?

    /// Workspace tab strip (reuses/generalizes the current TabBarView grammar; §2)
    let workspaceTabBar = TabBarView()
    /// Version badge (M22): far right of the tab strip, left of "+"; display and click forwarding only (BG-1)
    let versionBadge = VersionBadgeView()
    /// The two row containers (used by UISelfTest to measure heights 28/36; §5)
    let tabRow = NSView()
    let toolbarRow = NSView()

    private let navControl = NSSegmentedControl()
    private let viewModeControl = NSSegmentedControl()
    private let layoutControl = NSSegmentedControl()
    private let sidebarButton = NSButton()
    private let airdropButton = NSButton()
    private let terminalButton = NSButton()
    private let tasksButton = NSButton()
    private let trashButton = TrashDeckButton()
    private var tabRowLeading: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        material = .titlebar
        blendingMode = .behindWindow
        state = .followsWindowActiveState
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    // MARK: Build

    private func build() {
        // ── Row 1: workspace tab strip ─────────────────────────────────────
        workspaceTabBar.translatesAutoresizingMaskIntoConstraints = false
        workspaceTabBar.itemHeight = 28
        workspaceTabBar.useTransparentBackground()
        workspaceTabBar.onSelect = { [weak self] i in self?.deckDelegate?.deckSelectWorkspace(i) }
        workspaceTabBar.onClose = { [weak self] i in self?.deckDelegate?.deckCloseWorkspace(i) }
        workspaceTabBar.onNew = { [weak self] in self?.deckDelegate?.deckNewWorkspace() }
        // Version badge embedded in the tab strip's trailing accessory slot (left of "+"; M22)
        workspaceTabBar.setTrailingAccessory(versionBadge)
        tabRow.translatesAutoresizingMaskIntoConstraints = false
        tabRow.addSubview(workspaceTabBar)

        // ── Row 2: icon toolbar (§6.1 official SF Symbols; §6.2 A1 left/right split) ──────
        // Left cluster: sidebar toggle (sidebar.leading)
        buildIconButton(sidebarButton, symbol: "sidebar.leading", fallback: "sidebar.left",
                        tooltipKey: "menu.toggleSidebar", action: #selector(sidebarClicked), target: self)
        // Left cluster: three navigation segments (chevron.backward / chevron.forward / arrow.up)
        navControl.segmentCount = 3
        navControl.trackingMode = .momentary
        let navSpecs = [("chevron.backward", "menu.back"), ("chevron.forward", "menu.forward"),
                        ("arrow.up", "menu.goUp")]
        for (i, s) in navSpecs.enumerated() {
            navControl.setImage(NSImage.officialSymbol(s.0, accessibility: L10n.t(s.1)), forSegment: i)
            navControl.setToolTip(L10n.t(s.1), forSegment: i)
            navControl.setWidth(26, forSegment: i)
        }
        navControl.target = self
        navControl.action = #selector(navClicked(_:))
        // Long-pressing back/forward -> pops up that direction's history menu (§3; a short press stays the momentary click action)
        let navLongPress = NSPressGestureRecognizer(target: self, action: #selector(navLongPressed(_:)))
        navLongPress.minimumPressDuration = 0.4
        navControl.addGestureRecognizer(navLongPress)
        // Left cluster: three view segments (square.grid.2x2 / list.bullet / rectangle.split.3x1)
        viewModeControl.segmentCount = 3
        viewModeControl.trackingMode = .selectOne
        let viewSpecs = [("square.grid.2x2", "menu.viewAsIcons"), ("list.bullet", "menu.viewAsList"),
                         ("rectangle.split.3x1", "menu.viewAsColumns")]
        for (i, s) in viewSpecs.enumerated() {
            viewModeControl.setImage(NSImage.officialSymbol(s.0, accessibility: L10n.t(s.1)), forSegment: i)
            viewModeControl.setToolTip(L10n.t(s.1), forSegment: i)
            viewModeControl.setWidth(28, forSegment: i)
        }
        viewModeControl.target = self
        viewModeControl.action = #selector(viewModeClicked(_:))

        // Right cluster: four action buttons (responder chain target=nil up to the active pane's FileListViewController; the tasks button targets ProgressWindowController)
        buildIconButton(airdropButton, symbol: "airdrop", fallback: "dot.radiowaves.left.and.right",
                        tooltipKey: "toolbar.airdrop",
                        action: #selector(FileListViewController.airdropSelected(_:)), target: nil)
        buildIconButton(terminalButton, symbol: "apple.terminal", fallback: "terminal",
                        tooltipKey: "toolbar.terminal",
                        action: #selector(FileListViewController.openInTerminal(_:)), target: nil)
        buildIconButton(tasksButton, symbol: "arrow.up.arrow.down", fallback: nil,
                        tooltipKey: "toolbar.tasks",
                        action: #selector(ProgressWindowController.toggleVisible(_:)),
                        target: ProgressWindowController.shared)
        // Trash button semantics (v0.19.17, user report): **a click always opens the Trash**, regardless of selection.
        // Why not "delete if something is selected, open otherwise": users almost always have something selected (the screenshot did),
        // so someone heading for the Trash would delete the selected files. Deletion stays on ⌘⌫/context menu/dragging onto this button.
        buildIconButton(trashButton, symbol: "trash", fallback: nil, tooltipKey: "toolbar.trash",
                        action: #selector(trashClicked), target: self)
        // The tooltip should include the usage hint "drag here = move to Trash", but the **accessibility label** should not be a whole sentence:
        // buildIconButton uses one key for both AX label and toolTip, and VoiceOver would read the whole sentence.
        trashButton.toolTip = L10n.t("toolbar.trash.help")
        trashButton.onDropFiles = { [weak self] urls, src in
            self?.deckDelegate?.deckDropOnTrash(urls, from: src)
        }
        // Empty Trash lives on the **context menu** (like the Trash in the Dock):
        // not on the blank-space directory menu, which has an "exactly 5 items" assertion that one more item would break;
        // and not on left click, which is already "open Trash": an irreversible action should not share a click with navigation.
        trashButton.onEmptyTrash = { [weak self] in self?.deckDelegate?.deckEmptyTrash() }
        // Right cluster: five layout segments (rectangle family; PaneLayout.symbolName matches the §6.1 table)
        layoutControl.segmentCount = PaneLayout.allCases.count
        layoutControl.trackingMode = .selectOne
        for (i, layout) in PaneLayout.allCases.enumerated() {
            layoutControl.setImage(NSImage.officialSymbol(layout.symbolName, accessibility: layout.localizedName),
                                   forSegment: i)
            layoutControl.setToolTip(layout.localizedName, forSegment: i)
            layoutControl.setWidth(28, forSegment: i)
        }
        layoutControl.target = self
        layoutControl.action = #selector(layoutClicked(_:))

        // A1 left cluster: sidebar | navigation | view (8pt between clusters + hairline = 16pt visual gap)
        let leftStack = NSStackView(views: [
            sidebarButton, hairlineV(), navControl, hairlineV(), viewModeControl,
        ])
        leftStack.orientation = .horizontal
        leftStack.alignment = .centerY
        leftStack.spacing = 8
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        // A1 right cluster: four action buttons (4pt inside) | five layout segments
        let actionsStack = NSStackView(views: [airdropButton, terminalButton, tasksButton, trashButton])
        actionsStack.orientation = .horizontal
        actionsStack.alignment = .centerY
        actionsStack.spacing = 4
        let rightStack = NSStackView(views: [actionsStack, hairlineV(), layoutControl])
        rightStack.orientation = .horizontal
        rightStack.alignment = .centerY
        rightStack.spacing = 8
        rightStack.translatesAutoresizingMaskIntoConstraints = false

        toolbarRow.translatesAutoresizingMaskIntoConstraints = false
        toolbarRow.addSubview(leftStack)
        toolbarRow.addSubview(rightStack)

        // ── Hairline separators ─────────────────────────────────────────────
        let hair1 = hairlineH(), hair2 = hairlineH()
        for v in [tabRow, hair1, toolbarRow, hair2] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        tabRowLeading = workspaceTabBar.leadingAnchor.constraint(equalTo: tabRow.leadingAnchor)
        NSLayoutConstraint.activate([
            // Row 1
            tabRow.topAnchor.constraint(equalTo: topAnchor),
            tabRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabRow.heightAnchor.constraint(equalToConstant: Self.tabRowHeight),
            tabRowLeading,
            workspaceTabBar.trailingAnchor.constraint(equalTo: tabRow.trailingAnchor),
            workspaceTabBar.topAnchor.constraint(equalTo: tabRow.topAnchor),
            workspaceTabBar.bottomAnchor.constraint(equalTo: tabRow.bottomAnchor),
            // Hairline 1
            hair1.topAnchor.constraint(equalTo: tabRow.bottomAnchor),
            hair1.leadingAnchor.constraint(equalTo: leadingAnchor),
            hair1.trailingAnchor.constraint(equalTo: trailingAnchor),
            hair1.heightAnchor.constraint(equalToConstant: 1),
            // Row 2: left cluster flush with leading, right cluster flush with trailing, flexible middle = window drag handle
            toolbarRow.topAnchor.constraint(equalTo: hair1.bottomAnchor),
            toolbarRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbarRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbarRow.heightAnchor.constraint(equalToConstant: Self.toolbarRowHeight),
            leftStack.leadingAnchor.constraint(equalTo: toolbarRow.leadingAnchor, constant: 8),
            leftStack.centerYAnchor.constraint(equalTo: toolbarRow.centerYAnchor),
            rightStack.trailingAnchor.constraint(equalTo: toolbarRow.trailingAnchor, constant: -8),
            rightStack.centerYAnchor.constraint(equalTo: toolbarRow.centerYAnchor),
            leftStack.trailingAnchor.constraint(lessThanOrEqualTo: rightStack.leadingAnchor, constant: -8),
            // Hairline 2 (deck bottom)
            hair2.topAnchor.constraint(equalTo: toolbarRow.bottomAnchor),
            hair2.leadingAnchor.constraint(equalTo: leadingAnchor),
            hair2.trailingAnchor.constraint(equalTo: trailingAnchor),
            hair2.heightAnchor.constraint(equalToConstant: 1),
            hair2.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: Sync (fed back by MainWindowController on active pane/location/layout changes)

    func updateWorkspaces(titles: [String], active: Int) {
        workspaceTabBar.update(titles: titles, active: active)
    }

    func syncViewMode(_ raw: Int) {
        if viewModeControl.selectedSegment != raw { viewModeControl.selectedSegment = raw }
    }

    func syncLayout(_ layout: PaneLayout) {
        let idx = PaneLayout.allCases.firstIndex(of: layout) ?? 0
        if layoutControl.selectedSegment != idx { layoutControl.selectedSegment = idx }
    }

    /// Navigation segment enabled state reflects canGoBack/Forward/Up
    func syncNav(canBack: Bool, canForward: Bool, canUp: Bool) {
        navControl.setEnabled(canBack, forSegment: 0)
        navControl.setEnabled(canForward, forSegment: 1)
        navControl.setEnabled(canUp, forSegment: 2)
    }

    /// Action button validation (FG-1: equivalent to the old toolbar autovalidate): AirDrop needs a selection;
    /// terminal/tasks/trash are always available: the trash button now means "open Trash", unrelated to selection
    /// (the old `trashButton.isEnabled = hasSelection` kept it gray so long that the user concluded "there is no Trash feature").
    func validateActions(hasSelection: Bool) {
        airdropButton.isEnabled = hasSelection
        terminalButton.isEnabled = true
        tasksButton.isEnabled = true
        trashButton.isEnabled = true
    }

    /// Sidebar collapsed state: the tab row gives way to the traffic lights (§1)
    func setSidebarCollapsed(_ collapsed: Bool) {
        tabRowLeading.constant = collapsed ? Self.trafficLightInset : 0
    }

    // MARK: Action forwarding

    @objc private func sidebarClicked() { deckDelegate?.deckToggleSidebar() }

    @objc private func trashClicked() { deckDelegate?.deckOpenTrash() }

    // ---- Self-test channel (I-62) ----
    var uiTestTrashButtonEnabled: Bool { trashButton.isEnabled }
    func uiTestClickTrash() { trashButton.performClick(nil) }
    /// Real drag wiring: an injection seam cannot prove AppKit will deliver drags to this button (it must have registerForDraggedTypes)
    var uiTestTrashAcceptsFileURLDrags: Bool {
        trashButton.registeredDraggedTypes.contains(.fileURL)
    }
    /// Trash button context menu: goes through **the path AppKit really calls**, `menu(for:)`, not buildContextMenu() directly.
    /// The first version called the builder directly and stayed green with the `menu(for:)` override removed, proving only "the menu can be built",
    /// not "a right click really brings it up".
    func uiTestTrashContextMenu() -> NSMenu? {
        guard let ev = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero,
                                          modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window?.windowNumber ?? 0, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: 1) else { return nil }
        return trashButton.menu(for: ev)
    }
    /// Goes through the trash button's real drop landing logic (pasteboard is injectable, the system drag pasteboard is untouched)
    func uiTestDropOnTrash(from pasteboard: NSPasteboard, sourceWindow: NSWindow? = nil) -> Bool {
        trashButton.acceptDrop(from: pasteboard, sourceWindow: sourceWindow)
    }

    @objc private func navClicked(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: deckDelegate?.deckGoBack()
        case 1: deckDelegate?.deckGoForward()
        case 2: deckDelegate?.deckGoUp()
        default: break
        }
    }

    /// Long-pressing a navigation segment pops up the history menu: segment 0 = back / segment 1 = forward (segment 2, up, has no history and is ignored)
    private struct NavHistoryPick { let forward: Bool; let index: Int }

    @objc private func navLongPressed(_ gr: NSPressGestureRecognizer) {
        guard gr.state == .began, navControl.bounds.width > 0 else { return }
        let loc = gr.location(in: navControl)
        let seg = Int(loc.x / (navControl.bounds.width / 3))
        let forward: Bool
        if seg <= 0 { forward = false } else if seg == 1 { forward = true } else { return }
        guard let urls = deckDelegate?.deckHistory(forward: forward), !urls.isEmpty else { return }
        let menu = NSMenu()
        for (i, url) in urls.enumerated() {
            let item = menu.addItem(withTitle: url.path == "/" ? "/" : url.lastPathComponent,
                                    action: #selector(navHistoryPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NavHistoryPick(forward: forward, index: i)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 14, height: 14)
            item.image = icon
        }
        menu.popUp(positioning: nil, at: NSPoint(x: loc.x, y: navControl.bounds.height + 2), in: navControl)
    }

    @objc private func navHistoryPicked(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? NavHistoryPick else { return }
        deckDelegate?.deckJumpHistory(forward: pick.forward, index: pick.index)
    }

    @objc private func viewModeClicked(_ sender: NSSegmentedControl) {
        guard let mode = PaneViewMode(rawValue: sender.selectedSegment) else { return }
        deckDelegate?.deckSetViewMode(mode)
    }

    @objc private func layoutClicked(_ sender: NSSegmentedControl) {
        let layouts = PaneLayout.allCases
        guard layouts.indices.contains(sender.selectedSegment) else { return }
        deckDelegate?.deckSetLayout(layouts[sender.selectedSegment])
    }

    // MARK: Window dragging + double-click zoom (custom title bar convention; mouseDownCanMoveWindow=false so double-clicks can be intercepted)

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let window else { super.mouseDown(with: event); return }
        if event.clickCount == 2 {
            performDoubleClickAction(on: window)
        } else {
            window.performDrag(with: event)  // system-managed drag (respects Spaces/edge snapping)
        }
    }

    /// Double-clicking blank deck space = system zoom behavior (per the system preference AppleActionOnDoubleClick)
    private func performDoubleClickAction(on window: NSWindow) {
        let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
        switch action {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)  // Maximize/Zoom (default)
        }
    }

    // MARK: Tools

    private func buildIconButton(_ button: NSButton, symbol name: String, fallback: String?,
                                 tooltipKey: String, action: Selector, target: AnyObject?) {
        button.image = NSImage.officialSymbol(name, fallback: fallback, accessibility: L10n.t(tooltipKey))
        button.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        button.isBordered = false
        button.bezelStyle = .accessoryBarAction
        button.setButtonType(.momentaryChange)
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = L10n.t(tooltipKey)
        button.target = target
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    /// Vertical hairline between clusters (20pt tall, separatorColor)
    private func hairlineV() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.separatorColor.cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            v.widthAnchor.constraint(equalToConstant: 1),
            v.heightAnchor.constraint(equalToConstant: 20),
        ])
        return v
    }

    /// Horizontal hairline (NSBox separator, system semantic color)
    private func hairlineH() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}

/// Deck trash button: click = open Trash (action wired by TopDeckView), dragging files in = move to Trash.
/// Drop shape copied from BreadcrumbBar.SegmentButton (same volume/highlight/landing rules, nothing newly invented).
/// This layer has zero write APIs: landings always go through coordinator -> OperationKernel (BG-1).
@MainActor
final class TrashDeckButton: NSButton {
    var onDropFiles: (([URL], NSWindow?) -> Void)?
    var onEmptyTrash: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    /// Context menu: a single item, "Empty Trash". Shared by building and clicking (self-tests can fetch this menu directly)
    func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        let item = menu.addItem(withTitle: L10n.t("menu.emptyTrash"),
                                action: #selector(emptyTrashClicked), keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: "trash.slash", accessibilityDescription: nil)
        return menu
    }

    override func menu(for event: NSEvent) -> NSMenu? { buildContextMenu() }

    @objc private func emptyTrashClicked() { onEmptyTrash?() }

    /// Landing seam: pasteboard is injectable, self-tests use a private board (the user's real drag pasteboard is untouched)
    @discardableResult
    func acceptDrop(from pasteboard: NSPasteboard, sourceWindow: NSWindow? = nil) -> Bool {
        guard let urls = pasteboard.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        onDropFiles?(urls, sourceWindow)
        return true
    }

    private func hasFiles(_ info: any NSDraggingInfo) -> Bool {
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return !(urls?.isEmpty ?? true)
    }

    private func setDropHighlight(_ on: Bool) {
        layer?.backgroundColor = on
            ? Theme.accent.withAlphaComponent(0.10).cgColor
            : NSColor.clear.cgColor
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let ok = hasFiles(sender)
        setDropHighlight(ok)
        return ok ? .move : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        hasFiles(sender) ? .move : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { setDropHighlight(false) }
    override func draggingEnded(_ sender: any NSDraggingInfo) { setDropHighlight(false) }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { hasFiles(sender) }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        setDropHighlight(false)
        // For in-app drags draggingSource is the initiating view, which gives the source window
        return acceptDrop(from: sender.draggingPasteboard,
                          sourceWindow: (sender.draggingSource as? NSView)?.window)
    }
}
