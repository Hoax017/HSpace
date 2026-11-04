import AppKit

/// Per-pane compact tab bar: select/new/close/middle-click close (QSpace per-pane tab semantics)
@MainActor
final class TabBarView: NSView {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNew: (() -> Void)?

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

        addSubview(scroll)
        addSubview(accessoryHost)
        addSubview(addButton)
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
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, title) in titles.enumerated() {
            let item = TabItemView(title: title, isActive: i == active,
                                   closable: titles.count > 1, height: itemHeight)
            item.onSelect = { [weak self] in self?.onSelect?(i) }
            item.onClose = { [weak self] in self?.onClose?(i) }
            stack.addArrangedSubview(item)
        }
    }

    @objc private func newTab() { onNew?() }

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

/// A single tab (pod style; close button on hover; middle-click closes)
@MainActor
private final class TabItemView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let isActive: Bool
    private let closable: Bool
    private var tracking: NSTrackingArea?

    /// Same as TabBarView: in the title bar area window dragging must not take over, or mouseDown never arrives (I-12)
    override var mouseDownCanMoveWindow: Bool { false }

    init(title: String, isActive: Bool, closable: Bool, height: CGFloat) {
        self.isActive = isActive
        self.closable = closable
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = isActive
            ? Theme.accent.withAlphaComponent(0.18).cgColor
            : NSColor.clear.cgColor

        label.stringValue = title
        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingTail
        label.textColor = isActive ? .labelColor : .secondaryLabelColor
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

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
        onSelect?()
    }

    override func otherMouseDown(with event: NSEvent) {
        if closable, event.buttonNumber == 2 { onClose?() }
    }

    @objc private func closeTab() { onClose?() }
}
