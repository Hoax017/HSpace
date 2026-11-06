import AppKit
import TabDrag

/// Per-pane compact tab bar: select/new/close/middle-click close (QSpace per-pane tab semantics)
@MainActor
final class TabBarView: NSView {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNew: (() -> Void)?
    /// A tab was dragged to another place in this bar
    var onMove: ((_ from: Int, _ to: Int) -> Void)?
    /// A tab was dropped clear of its window; the point is in screen coordinates
    var onDetach: ((_ index: Int, _ screenPoint: NSPoint) -> Void)?
    /// A tab from another window was dropped in this bar's gap
    var onAdopt: ((_ payload: TabDragPayload, _ gap: Int) -> Void)?

    private static let dragType = NSPasteboard.PasteboardType(TabDragPayload.pasteboardType)
    /// Shows where a dragged tab would land (positioned by frame, no layout change: FG-4)
    private let insertionMark = NSView()
    private var draggedIndex: Int?

    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private let addButton = NSButton()
    /// Trailing accessory slot (used by the deck workspace tab strip: the version badge sits here, left of the "+" button).
    /// With no accessory the width shrinks to 0 (low-priority width==0 fallback); with one it grows with the content.
    private let accessoryHost = NSView()

    /// Tab pod height (the deck workspace tab strip sets 28: QSpace density with a 40 row height)
    var itemHeight: CGFloat = 20

    /// The deck sits in the title bar area (fullSizeContentView): without this override clicks are swallowed by window dragging (I-12)
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 2)
        stack.translatesAutoresizingMaskIntoConstraints = false

        scroll.documentView = stack
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.translatesAutoresizingMaskIntoConstraints = false

        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: L10n.t("tab.new"))
        addButton.isBordered = false
        addButton.bezelStyle = .accessoryBarAction
        addButton.target = self
        addButton.action = #selector(newTab)
        addButton.translatesAutoresizingMaskIntoConstraints = false

        accessoryHost.translatesAutoresizingMaskIntoConstraints = false
        let emptyWidth = accessoryHost.widthAnchor.constraint(equalToConstant: 0)
        emptyWidth.priority = .init(1)   // lowest priority: overridden by content constraints with an accessory, shrinks to 0 without one
        emptyWidth.isActive = true

        insertionMark.wantsLayer = true
        insertionMark.isHidden = true
        registerForDraggedTypes([Self.dragType])

        addSubview(scroll)
        addSubview(accessoryHost)
        addSubview(addButton)
        addSubview(insertionMark)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: accessoryHost.leadingAnchor, constant: -2),
            stack.heightAnchor.constraint(equalTo: scroll.heightAnchor),
            accessoryHost.centerYAnchor.constraint(equalTo: centerYAnchor),
            accessoryHost.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -8),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            addButton.widthAnchor.constraint(equalToConstant: 20),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    /// Deck style (M17): transparent background showing TopDeckView's .titlebar material (the workspace tab strip reuses the same tab grammar)
    func useTransparentBackground() {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    /// Any point in the bar belongs to a pod as long as its x falls within that pod's horizontal range.
    ///
    /// This is not just "include the 6pt dead zones above and below": it is **the actual fix** for "clicking tab text does not switch" (user report).
    /// Tested on a real machine: the raw hitTest at the center of a pod returns the **NSScrollView**, neither the pod nor the label;
    /// in a full-size title bar window this scroll view has automatic insets, so its hit geometry is out of line with the drawn pods
    /// (with automaticallyAdjustsContentInsets off, the raw hit becomes NSStackView and still does not reach the pod).
    /// NSScrollView.mouseDown does nothing, so the click dies there, and only shortcuts can switch.
    /// Dispatching the hit to the pod by x at the bar level bypasses that geometry. Counter-proof: remove this method,
    /// and a click dispatched through the real window gives `active after click 1→1`, reproducing the user's symptom exactly.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        // Already hit a pod / plus button / accessory -> as usual
        if hit !== self, hit !== scroll, hit !== scroll.contentView, hit !== stack { return hit }
        // Hit blank space: find the pod by x
        for case let item as TabItemView in stack.arrangedSubviews where !item.isHidden {
            let r = item.convert(item.bounds, to: self)
            if point.x >= r.minX, point.x <= r.maxX, bounds.contains(point) { return item }
        }
        return hit
    }

    func update(titles: [String], active: Int) {
        // Updated in place: selecting happens on mouse down, and a tab rebuilt there would never see its own drag
        let existing = items
        for (i, title) in titles.enumerated() {
            let item = i < existing.count ? existing[i] : makeItem()
            item.index = i
            item.configure(title: title, isActive: i == active, closable: titles.count > 1)
        }
        existing.dropFirst(titles.count).forEach { $0.removeFromSuperview() }
    }

    private var items: [TabItemView] { stack.arrangedSubviews.compactMap { $0 as? TabItemView } }

    private func makeItem() -> TabItemView {
        let item = TabItemView(height: itemHeight)
        item.onSelect = { [weak self, weak item] in
            if let self, let item { self.onSelect?(item.index) }
        }
        item.onClose = { [weak self, weak item] in
            if let self, let item { self.onClose?(item.index) }
        }
        item.onBeginDrag = { [weak self, weak item] event in
            if let self, let item { self.beginDrag(of: item, with: event) }
        }
        stack.addArrangedSubview(item)
        return item
    }

    @objc private func newTab() { onNew?() }

    // MARK: Dragging tabs (L34)

    private func beginDrag(of item: TabItemView, with event: NSEvent) {
        guard let windowNumber = window?.windowNumber else { return }
        let pasteboardItem = NSPasteboardItem()
        do {
            pasteboardItem.setData(try TabDragPayload(windowNumber: windowNumber, index: item.index).encoded(), forType: Self.dragType)
        } catch {
            return   // two integers always encode; without a payload there is simply no drag
        }
        let dragging = NSDraggingItem(pasteboardWriter: pasteboardItem)
        dragging.setDraggingFrame(item.bounds, contents: item.snapshot())
        draggedIndex = item.index
        item.beginDraggingSession(with: [dragging], event: event, source: self)
    }

    private var itemEdges: [(min: Double, max: Double)] {
        items.map { item in
            let frame = item.convert(item.bounds, to: self)
            return (Double(frame.minX), Double(frame.maxX))
        }
    }

    private func gap(for info: any NSDraggingInfo) -> Int {
        TabMove.gap(at: Double(convert(info.draggingLocation, from: nil).x), edges: itemEdges)
    }

    private func showInsertionMark(at gap: Int) {
        let edges = itemEdges
        guard !edges.isEmpty else { return }
        let x = gap < edges.count ? edges[gap].min : edges[edges.count - 1].max
        insertionMark.layer?.backgroundColor = Theme.accent.cgColor
        insertionMark.frame = NSRect(x: x - 1, y: 4, width: 2, height: bounds.height - 8)
        insertionMark.isHidden = false
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard payload(of: sender) != nil else { return [] }
        showInsertionMark(at: gap(for: sender))
        return .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        insertionMark.isHidden = true
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        insertionMark.isHidden = true
        guard let payload = payload(of: sender) else { return false }
        return drop(payload, inGap: gap(for: sender))
    }

    private func payload(of info: any NSDraggingInfo) -> TabDragPayload? {
        info.draggingPasteboard.data(forType: Self.dragType).flatMap(TabDragPayload.decoded)
    }

    /// True when the drop is taken. A drop back on the tab's own place counts: nothing moves, and nothing may detach.
    func drop(_ payload: TabDragPayload, inGap gap: Int) -> Bool {
        guard payload.windowNumber == window?.windowNumber else {
            // Next turn: taking the tab can close the window whose drag session is still finishing
            DispatchQueue.main.async { [weak self] in self?.onAdopt?(payload, gap) }
            return true
        }
        if let to = TabMove.destination(from: payload.index, gap: gap, count: items.count) {
            onMove?(payload.index, to)
        }
        return true
    }

    // ---- Test channel ----
    var testItemCount: Int { items.count }
    func testItem(_ i: Int) -> NSView { items[i] }
    func testItemTitle(_ i: Int) -> String { items[i].title }
    func testItemIsActive(_ i: Int) -> Bool { items[i].isActive }
    var testInsertionMarkFrame: NSRect? { insertionMark.isHidden ? nil : insertionMark.frame }
    func testShowInsertionMark(gap: Int) { showInsertionMark(at: gap) }

    // ---- Self-test channel (I-72) ----
    /// Frame of pod i in this bar's coordinate system
    func uiTestItemFrame(_ i: Int) -> NSRect? {
        let items = stack.arrangedSubviews.compactMap { $0 as? TabItemView }
        guard items.indices.contains(i) else { return nil }
        return items[i].convert(items[i].bounds, to: self)
    }
    /// Whether pod i accepts the "first" click (no double click needed when coming from another app)
    func uiTestItemAcceptsFirstMouse(_ i: Int) -> Bool {
        let items = stack.arrangedSubviews.compactMap { $0 as? TabItemView }
        return items.indices.contains(i) && items[i].acceptsFirstMouse(for: nil)
    }
    /// Does a **real** hitTest at a point in this bar's coordinates and reports whether it hits pod i (same path AppKit uses to dispatch mouseDown)
    func uiTestHitsItem(_ i: Int, at p: NSPoint) -> Bool {
        guard let sp = superview else { return false }
        let items = stack.arrangedSubviews.compactMap { $0 as? TabItemView }
        guard items.indices.contains(i) else { return false }
        return hitTest(convert(p, to: sp)) === items[i]
    }
    /// Delivers mouseDown **directly to the view resolved by hitTest** (deterministic: skips the app activation gate).
    /// The only difference from real AppKit dispatch is the "activate the app first" layer, which randomly eats the first click while the user is using the machine;
    /// on the real gate the same code went 1 green, 2 red over 3 rounds. Hit resolution itself (hitTest above) is the actual fix.
    func uiTestClickResolved(at p: NSPoint, in window: NSWindow) -> String {
        guard let sp = superview, let target = hitTest(convert(p, to: sp)),
              let ev = NSEvent.mouseEvent(with: .leftMouseDown, location: convert(p, to: nil),
                                          modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: 1) else { return "nil" }
        target.mouseDown(with: ev)
        return String(describing: type(of: target))
    }

    /// Clicks via the **window's real event dispatch** (NSWindow.sendEvent -> title bar region check -> hitTest ->
    /// mouseDownCanMoveWindow -> target view). Calling target.mouseDown directly skips every one of those stages,
    /// and the user's "click does not switch" could well die in them. postEvent rather than sendEvent:
    /// if AppKit opens a tracking loop on down, the up that follows ends it, so the self-test cannot hang.
    func uiTestClick(at p: NSPoint, in window: NSWindow) {
        let loc = convert(p, to: nil)
        let t = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: loc, modifierFlags: [],
                                            timestamp: t, windowNumber: window.windowNumber, context: nil,
                                            eventNumber: 0, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: loc, modifierFlags: [],
                                          timestamp: t + 0.05, windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: 0) else { return }
        // Hand it straight to the window, not NSApp: the self-test runs on a machine in use, the app is often not active,
        // and the NSApp layer eats the first click as "activation" (on the real gate the same code gave 1→0 in one round and 1→1 in two).
        // window.sendEvent still goes through the NSThemeFrame title bar region check -> hitTest -> mouseDownCanMoveWindow -> target view.
        window.sendEvent(down)
        window.sendEvent(up)
    }

    /// Sets the trailing accessory (version badge); nil clears it. The accessory fills accessoryHost, whose width follows the accessory's content.
    func setTrailingAccessory(_ view: NSView?) {
        accessoryHost.subviews.forEach { $0.removeFromSuperview() }
        guard let view else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        accessoryHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: accessoryHost.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: accessoryHost.trailingAnchor),
            view.centerYAnchor.constraint(equalTo: accessoryHost.centerYAnchor),
        ])
    }
}

extension TabBarView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard let index = draggedIndex else { return }
        draggedIndex = nil
        let end = TabDragEnd(accepted: operation != [], cancelled: NSEvent.pressedMouseButtons & 1 != 0,
                             insideSourceWindow: window?.frame.contains(screenPoint) ?? true, tabCount: testItemCount)
        if end.detaches { onDetach?(index, screenPoint) }
    }
}

/// A single tab (pod style; close button on hover; middle-click closes)
@MainActor
private final class TabItemView: NSView {
    /// Pointer travel that turns a press into a drag
    private static let dragThreshold: CGFloat = 4

    var index = 0
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onBeginDrag: ((NSEvent) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private(set) var isActive = false
    private var closable = false
    private var tracking: NSTrackingArea?
    /// Where the press began; nil once a drag has started or the button is up
    private var pressPoint: NSPoint?

    /// Same as TabBarView: in the title bar area window dragging must not take over, or mouseDown never arrives (I-12)
    override var mouseDownCanMoveWindow: Bool { false }

    var title: String { label.stringValue }

    init(height: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5

        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L10n.t("tab.close"))
        closeButton.symbolConfiguration = .init(pointSize: 7, weight: .bold)
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeTab)
        closeButton.isHidden = true
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(closeButton)
        // I-23: text must sit dead center in the pod: symmetric 12/12 padding + centered alignment;
        // the close button overlays the left padding on hover and stays out of layout (reserving room for it used to offset the text)
        label.alignment = .center
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 12),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(lessThanOrEqualToConstant: 160),
            heightAnchor.constraint(equalToConstant: height),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    func configure(title: String, isActive: Bool, closable: Bool) {
        self.isActive = isActive
        self.closable = closable
        label.stringValue = title
        label.textColor = isActive ? .labelColor : .secondaryLabelColor
        layer?.backgroundColor = isActive ? Theme.accent.withAlphaComponent(0.18).cgColor : NSColor.clear.cgColor
        if !closable { closeButton.isHidden = true }
        setAccessibilityLabel(title)
        setAccessibilityValue(isActive ? 1 : 0)
    }

    override func accessibilityPerformPress() -> Bool {
        onSelect?()
        return true
    }

    /// What follows the pointer during a drag
    func snapshot() -> NSImage {
        let image = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            image.addRepresentation(rep)
        }
        return image
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        if closable { closeButton.isHidden = false }
    }

    override func mouseExited(with event: NSEvent) {
        closeButton.isHidden = true
    }

    /// The **first** click from another app must switch (same as Safari tabs). With the default false, the first click only activates the window
    /// and sends no mouseDown: a user returning from another app clicks a tab, "nothing happens", and only the second click works.
    /// (Note: I once blamed the NSTextField inside the pod for swallowing the click; a real-machine hitTest shows the label passes through,
    /// so that root cause does not hold and the related change was reverted.)
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressPoint = event.locationInWindow
        onSelect?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressPoint,
              hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= Self.dragThreshold else { return }
        pressPoint = nil
        onBeginDrag?(event)
    }

    override func mouseUp(with event: NSEvent) {
        pressPoint = nil
    }

    override func otherMouseDown(with event: NSEvent) {
        if closable, event.buttonNumber == 2 { onClose?() }
    }

    @objc private func closeTab() { onClose?() }
}
