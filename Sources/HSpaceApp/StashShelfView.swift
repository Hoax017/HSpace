import AppKit
import StashStore

/// Stash shelf section (QSpace-style stacked pile, M14/M16/M17): B2 hover-reveal.
/// Normally only the pile + count pill are visible (centered); after a 150ms hover an action bar floats up at the bottom (overlay, no layout change);
/// hovering a drag shows an accent hairline inner ring as the drop highlight. Implicit semantics: no text on actions, official SF Symbols + tooltips.
@MainActor
final class StashShelfView: NSView {
    private(set) weak var controller: StashShelfController?

    private let emptyIcon = NSImageView()
    private let emptyLabel = NSTextField(labelWithString: L10n.t("stash.empty"))
    private let stackPile = StashPileView()
    private let countButton = NSButton()
    private let contentGroup = NSStackView()
    private let dropCatcher = StashDropCatcher()
    /// Action bar floated on hover (overlay: frame-positioned, not in the main Auto Layout chain, no layout change; FG-4 spatial debounce)
    private let floatBar = NSVisualEffectView()
    private let floatButtons = NSStackView()
    /// Drop highlight: accent hairline inner ring (frame-positioned overlay ring)
    private let ringView = NSView()
    private var heightConstraint: NSLayoutConstraint?
    private var hoverTimer: Timer?
    private var tracking: NSTrackingArea?

    /// Constant height (no jump between empty and filled): the pile area stays visually centered (QSpace spec)
    private static let emptyHeight: CGFloat = 148
    private static let filledHeight: CGFloat = 148

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])

        emptyIcon.image = NSImage.officialSymbol("tray.and.arrow.down",
                                                 accessibility: L10n.t("sidebar.stash"))
        emptyIcon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        emptyIcon.contentTintColor = .tertiaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.textColor = .tertiaryLabelColor

        // Count pill: "N ⌄" / "name ⌄" (10% accent tint, tabular-nums); click = per-item management menu
        countButton.bezelStyle = .accessoryBarAction
        countButton.isBordered = false
        countButton.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        countButton.imagePosition = .imageTrailing
        countButton.image = NSImage.officialSymbol("chevron.down", accessibility: L10n.t("stash.manage"))
        countButton.symbolConfiguration = .init(pointSize: 8, weight: .semibold)
        countButton.contentTintColor = .labelColor
        countButton.toolTip = L10n.t("stash.manage")
        countButton.target = self
        countButton.action = #selector(showManageMenu(_:))
        countButton.wantsLayer = true
        countButton.layer?.cornerRadius = 8

        // Pile column (pile + count pill): the only group normally visible, centered in the 148pt area
        contentGroup.orientation = .vertical
        contentGroup.spacing = 2
        contentGroup.alignment = .centerX
        contentGroup.addArrangedSubview(stackPile)
        contentGroup.addArrangedSubview(countButton)

        for sub in [emptyIcon, emptyLabel, contentGroup] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
        }

        // Hover bar (overlay material + hairline border + shadow; five 20×20 buttons, spacing 4: copy/move/AirDrop/clear/more)
        buildFloatBar()

        // Accent hairline inner ring (drop highlight on drag hover; frame-positioned)
        ringView.wantsLayer = true
        ringView.layer?.borderWidth = 1
        ringView.layer?.cornerRadius = 8
        ringView.isHidden = true
        addSubview(ringView)
        // The three accent layer colors (pill background / ring border / ring background) are set in one place
        // and re-resolved on theme broadcast and light/dark switches. They used to read cgColor once in init, so runtime accent/appearance changes didn't refresh.
        applyAccentColors()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: .hspaceThemeChanged, object: nil)

        // Transparent catcher on top (added last = frontmost in z-order): drop target lookup goes by registered views, regardless of hitTest,
        // so one view takes over the whole area; hitTest=nil lets clicks/hover pass through to the buttons and pile
        dropCatcher.shelf = self
        dropCatcher.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dropCatcher)
        NSLayoutConstraint.activate([
            dropCatcher.topAnchor.constraint(equalTo: topAnchor),
            dropCatcher.bottomAnchor.constraint(equalTo: bottomAnchor),
            dropCatcher.leadingAnchor.constraint(equalTo: leadingAnchor),
            dropCatcher.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        let height = heightAnchor.constraint(equalToConstant: Self.emptyHeight)
        heightConstraint = height
        NSLayoutConstraint.activate([
            height,
            // Empty state: icon + text centered as a whole (visually stable in the constant-height area)
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor, constant: 12),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            emptyIcon.trailingAnchor.constraint(equalTo: emptyLabel.leadingAnchor, constant: -8),
            emptyIcon.centerYAnchor.constraint(equalTo: emptyLabel.centerYAnchor),
            // Pile group centered as a whole (adapts to sidebar width, no hard-coded offset; pile can enlarge to 112×100)
            contentGroup.centerXAnchor.constraint(equalTo: centerXAnchor),
            contentGroup.centerYAnchor.constraint(equalTo: centerYAnchor),
            contentGroup.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            stackPile.widthAnchor.constraint(equalToConstant: 112),
            stackPile.heightAnchor.constraint(equalToConstant: 100),
        ])
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// The three accent layer colors in one place (appearance-aware: controlAccentColor resolves with light/dark)
    private func applyAccentColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let accent = Theme.accent
            countButton.layer?.backgroundColor = accent.withAlphaComponent(0.10).cgColor
            ringView.layer?.borderColor = accent.cgColor
            ringView.layer?.backgroundColor = accent.withAlphaComponent(0.06).cgColor
        }
    }

    @objc private func themeChanged() { applyAccentColors() }

    /// System light/dark switch: appearance-dependent colors such as controlAccentColor must be re-resolved
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAccentColors()
    }

    /// Hover bar (overlay: child button frames come from their own Auto Layout, but floatBar itself is frame-positioned)
    private func buildFloatBar() {
        floatBar.material = .menu
        floatBar.blendingMode = .withinWindow
        floatBar.state = .active
        floatBar.wantsLayer = true
        floatBar.layer?.cornerRadius = 8
        floatBar.layer?.borderWidth = 1
        floatBar.layer?.borderColor = NSColor.separatorColor.cgColor
        floatBar.shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.28)
            s.shadowBlurRadius = 8
            s.shadowOffset = NSSize(width: 0, height: -1)
            return s
        }()
        floatBar.isHidden = true
        floatBar.translatesAutoresizingMaskIntoConstraints = true  // Overlay: not in the main Auto Layout chain

        // Five buttons: copy/move/AirDrop/clear/more (§6.1 official symbols; 20×20)
        let specs: [(String, String?, String, Selector, Int)] = [
            ("doc.on.doc", nil, "stash.copyHere", #selector(performAction(_:)), StashAction.copyHere.tag),
            ("arrow.forward.square", nil, "stash.moveHere", #selector(performAction(_:)), StashAction.moveHere.tag),
            ("airdrop", "dot.radiowaves.left.and.right", "stash.airdrop", #selector(performAction(_:)), StashAction.airdrop.tag),
            ("trash", nil, "stash.clear", #selector(clearAll(_:)), 0),
            ("ellipsis.circle", nil, "stash.manage", #selector(showManageMenuFromButton(_:)), 0),
        ]
        for (symbol, fallback, key, action, tag) in specs {
            let button = NSButton()
            button.image = NSImage.officialSymbol(symbol, fallback: fallback, accessibility: L10n.t(key))
            button.symbolConfiguration = .init(pointSize: 12, weight: .medium)
            button.isBordered = false
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = L10n.t(key)
            button.target = self
            button.action = action
            button.tag = tag
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 20),
                button.heightAnchor.constraint(equalToConstant: 20),
            ])
            floatButtons.addArrangedSubview(button)
        }
        floatButtons.orientation = .horizontal
        floatButtons.alignment = .centerY
        floatButtons.spacing = 4
        floatButtons.translatesAutoresizingMaskIntoConstraints = false
        floatBar.addSubview(floatButtons)
        NSLayoutConstraint.activate([
            floatButtons.topAnchor.constraint(equalTo: floatBar.topAnchor, constant: 4),
            floatButtons.bottomAnchor.constraint(equalTo: floatBar.bottomAnchor, constant: -4),
            floatButtons.leadingAnchor.constraint(equalTo: floatBar.leadingAnchor, constant: 8),
            floatButtons.trailingAnchor.constraint(equalTo: floatBar.trailingAnchor, constant: -8),
        ])
        addSubview(floatBar)  // Added as a subview but frame-positioned (not in the main chain)
    }

    /// Controller injection (idempotent): takes over onChange to drive this section's refresh
    func attach(_ controller: StashShelfController) {
        guard self.controller !== controller else { return }
        self.controller = controller
        controller.onChange = { [weak self] in self?.refresh() }
        controller.start()
    }

    // MARK: UISelfTest measurement hooks (§6.3)
    /// Action bar normally hidden (floats up only on hover)
    var actionBarHidden: Bool { floatBar.isHidden }
    /// The bar is an overlay (frame-positioned, not in the main Auto Layout chain)
    var actionBarIsOverlay: Bool { floatBar.translatesAutoresizingMaskIntoConstraints }
    /// I-07 regression probe: horizontal offset of the filled contentGroup from this section's center (|·|≤2pt counts as centered)
    var contentGroupCenterOffsetX: CGFloat {
        guard !contentGroup.isHidden else { return 0 }
        layoutSubtreeIfNeeded()
        return contentGroup.frame.midX - bounds.midX
    }

    private func refresh() {
        let items = controller?.items ?? []
        let empty = items.isEmpty
        emptyIcon.isHidden = !empty
        emptyLabel.isHidden = !empty
        contentGroup.isHidden = empty
        heightConstraint?.constant = empty ? Self.emptyHeight : Self.filledHeight
        if empty { hideFloatBar() }

        guard let controller, !empty else { return }
        let resolved: [(item: StashItem, url: URL?)] = items.map { ($0, controller.store.resolve($0)) }
        stackPile.configure(urls: resolved.map(\.url))
        stackPile.onDragAll = { [weak self] in self?.allResolvedURLs() ?? [] }
        // Single item shows its name, multiple items show the count (QSpace convention)
        if resolved.count == 1 {
            countButton.title = resolved[0].url?.lastPathComponent ?? L10n.t("stash.missing")
        } else {
            countButton.title = String(resolved.count)
        }
    }

    private func allResolvedURLs() -> [URL] {
        guard let controller else { return [] }
        return controller.items.compactMap { controller.store.resolve($0) }
    }

    // MARK: Overlay positioning (floatBar bottom center / ringView inset); doesn't affect main-chain layout

    override func layout() {
        super.layout()
        ringView.frame = bounds.insetBy(dx: 4, dy: 4)
        let barSize = floatBar.fittingSize
        let w = max(barSize.width, 132)
        let h = max(barSize.height, 28)
        floatBar.frame = NSRect(x: (bounds.width - w) / 2,
                                y: 8,
                                width: w, height: h)
    }

    // MARK: hover-reveal (floats up after a 150ms hover, hides on exit; not during a drag)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        scheduleFloatBar()
    }

    override func mouseExited(with event: NSEvent) {
        hideFloatBar()
    }

    private func scheduleFloatBar() {
        guard !(controller?.items.isEmpty ?? true) else { return }  // No actions in the empty state
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, !(self.controller?.items.isEmpty ?? true), self.ringView.isHidden else { return }
                self.floatBar.isHidden = false
            }
        }
    }

    private func hideFloatBar() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        floatBar.isHidden = true
    }

    // MARK: "N ⌄" item management menu

    @objc private func showManageMenu(_ sender: NSButton) {
        guard let controller else { return }
        let menu = NSMenu()
        for item in controller.items {
            let url = controller.store.resolve(item)
            let row = NSMenuItem(title: url?.lastPathComponent ?? L10n.t("stash.missing"),
                                 action: nil, keyEquivalent: "")
            if let url {
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: 16, height: 16)
                row.image = icon
            }
            let sub = NSMenu()
            let remove = sub.addItem(withTitle: L10n.t("stash.remove"),
                                     action: #selector(removeOne(_:)), keyEquivalent: "")
            remove.target = self
            remove.representedObject = item.id
            row.submenu = sub
            menu.addItem(row)
        }
        menu.addItem(.separator())
        let clear = menu.addItem(withTitle: L10n.t("stash.clear"),
                                 action: #selector(clearAll(_:)), keyEquivalent: "")
        clear.target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc private func removeOne(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        controller?.remove(ids: [id])
    }

    // MARK: Actions (hover bar icon buttons)

    @objc private func performAction(_ sender: NSButton) {
        guard let action = StashAction.from(tag: sender.tag) else { return }
        controller?.perform(action)
    }

    @objc private func clearAll(_ sender: Any?) {
        controller?.clearAll()
    }

    /// "More" button: pops the item management menu (same source as "N ⌄")
    @objc private func showManageMenuFromButton(_ sender: NSButton) {
        showManageMenu(sender)
    }

    // MARK: Whole-area drop target (accepts files and directories; subviews forward to these three methods)

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Re-register after joining the sidebar's view hierarchy, in case an outer container rebuild swallowed the registration
        registerForDraggedTypes([.fileURL])
    }

    func dropHighlight(_ on: Bool) {
        // Drag hover: hide the bar, show the accent hairline inner ring (in-place feedback, no layout change)
        if on { hideFloatBar() }
        ringView.isHidden = !on
    }

    func dropOperation(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let has = sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return has ? .copy : []
    }

    func acceptDrop(_ sender: any NSDraggingInfo) -> Bool {
        dropHighlight(false)
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
            !urls.isEmpty else { return false }
        controller?.add(urls)
        return true
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let op = dropOperation(sender)
        dropHighlight(op != [])
        return op
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropOperation(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dropHighlight(false)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        dropHighlight(false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        acceptDrop(sender)
    }
}

extension StashAction {
    var tag: Int {
        switch self {
        case .copyHere: 1
        case .moveHere: 2
        case .airdrop: 3
        }
    }

    static func from(tag: Int) -> StashAction? {
        switch tag {
        case 1: .copyHere
        case 2: .moveHere
        case 3: .airdrop
        default: nil
        }
    }
}

/// Pile view: up to 3 offset icon layers (newest on top); dragging = dragging the whole stack out
@MainActor
private final class StashPileView: NSView {
    private var layers: [NSImageView] = []
    /// Fetches the whole stack's URLs on drag (lazily resolved to stay current)
    var onDragAll: (() -> [URL])?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])  // Drops on the pile area are forwarded to the section (so subviews don't shadow the parent)
        for _ in 0..<3 {
            let iv = NSImageView()
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.unregisterDraggedTypes()      // Image views never accept drops themselves
            iv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(iv)
            layers.append(iv)
        }
    }

    private var shelf: StashShelfView? { superview?.superview as? StashShelfView }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let op = shelf?.dropOperation(sender) ?? []
        shelf?.dropHighlight(op != [])
        return op
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        shelf?.dropOperation(sender) ?? []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        shelf?.dropHighlight(false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        shelf?.acceptDrop(sender) ?? false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    override func layout() {
        super.layout()
        // Offset stacking: lower layers shift 6pt/layer up-left, top layer centered (macOS drag-stack convention; pile enlarged to ~112×100)
        let size: CGFloat = 80
        let visibleLayers = layers.filter { !$0.isHidden }
        for (pos, iv) in visibleLayers.enumerated() {
            let depth = CGFloat(visibleLayers.count - 1 - pos)  // Top layer (last) has depth=0
            iv.frame = NSRect(x: (bounds.width - size) / 2 - depth * 6,
                              y: (bounds.height - size) / 2 + depth * 6 - 6,
                              width: size, height: size)
        }
    }

    /// urls order = order added to the shelf; takes the last 3, newest on top
    func configure(urls: [URL?]) {
        let tail = urls.suffix(3)
        for (i, iv) in layers.enumerated() {
            let idx = tail.count - (layers.count - i)  // Align to the tail
            if idx >= 0, let url = Array(tail)[idx] {
                let img = NSWorkspace.shared.icon(forFile: url.path)
                img.size = NSSize(width: 80, height: 80)
                iv.image = img
                iv.isHidden = false
            } else if idx >= 0 {
                iv.image = NSImage.officialSymbol("questionmark.square.dashed",
                                                  accessibility: L10n.t("stash.missing"))
                iv.isHidden = false
            } else {
                iv.isHidden = true
            }
        }
        needsLayout = true
        toolTip = L10n.t("stash.dragHint")
    }

    // Dragging the pile = dragging the whole stack out (one NSDraggingItem each, frames offset into a stack look)
    override func mouseDragged(with event: NSEvent) {
        let urls = onDragAll?() ?? []
        guard !urls.isEmpty else { return }
        let items = urls.enumerated().map { (i, url) -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            let offset = CGFloat(min(i, 3)) * 5
            item.setDraggingFrame(NSRect(x: bounds.midX - 32 + offset, y: bounds.midY - 32 + offset,
                                         width: 64, height: 64), contents: icon)
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }
}

extension StashPileView: NSDraggingSource {
    nonisolated func draggingSession(_ session: NSDraggingSession,
                                     sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .move, .generic]
    }
}


/// Stash shelf drop catcher: covers the section and registers fileURL; ordinary mouse events pass through (hitTest=nil),
/// while drop target lookup goes by registered views regardless of hitTest. One view taking over fixes subviews swallowing bubbling for good.
@MainActor
final class StashDropCatcher: NSView {
    weak var shelf: StashShelfView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let op = shelf?.dropOperation(sender) ?? []
        shelf?.dropHighlight(op != [])
        return op
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        shelf?.dropOperation(sender) ?? []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        shelf?.dropHighlight(false)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        shelf?.dropHighlight(false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        shelf?.acceptDrop(sender) ?? false
    }
}
