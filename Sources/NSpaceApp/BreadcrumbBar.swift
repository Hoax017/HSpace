import AppKit

/// Breadcrumb address bar (custom drawn, not NSPathControl: needs chevron subfolder popups and later per-segment drag and drop)
/// I-37 adaptive width: no horizontal scrolling; instead it reflows live with the pane width:
///     1. segment names over ~18 characters are middle-truncated (the full name goes in the toolTip);
///     2. when things do not fit, keep the root segment + some trailing segments, and collapse the middle levels into one "…" segment whose menu lists all collapsed levels;
///     3. resize / layout switches recompute through layout(), degrading smoothly from "show all" to "collapse step by step". Every level stays reachable.
/// Layout on a 4pt scale; clicking blank space or ⌘L switches to the path editor (PathEditorField)
@MainActor
final class BreadcrumbBar: NSView {
    var onNavigate: ((URL) -> Void)?
    var onBeginEditing: (() -> Void)?
    /// File drop intent on a segment, passed up: (urls, target ancestor directory, ⌥ force copy) -> Pane -> coordinator
    var onDropFiles: ((_ urls: [URL], _ target: URL, _ forceCopy: Bool) -> Void)?

    /// Character limit for one segment's display name: longer names are middle-truncated (the full name goes in the toolTip)
    private static let maxSegmentChars = 18
    /// Left and right inset (4pt steps)
    private static let edgeInset: CGFloat = 8
    /// Fixed width reserved for the chevron separator (4pt steps).
    /// 16 -> 8: the 4pt margin on each side of the segment hit box is **taken from here**, so each level's total width
    /// (glyph + segHitPadX×2 + chevronWidth = glyph + 16) is exactly what it was before the change,
    /// and the collapse threshold does not move right. Otherwise one path level fewer shows at the same width (measured in review: dualH 600 window,
    /// sidebar collapsed, 4-level path: all shown before the change, collapsed after).
    /// The chevron glyph measures 7pt and fits in 8pt; the hit box is now the full 20pt height,
    /// so 8×20=160pt² is still 54% larger than the former 16×6.5=104pt².
    private static let chevronWidth: CGFloat = 8
    /// Margin on each side of the segment hit box (4pt steps): a click just beside the name still belongs to this segment, not the neighboring chevron
    private static let segHitPadX: CGFloat = 4
    /// Segment hit width (pure function: layout and self-tests share one definition, no separate calculations)
    static func segmentHitWidth(glyphWidth: CGFloat) -> CGFloat {
        max(1, glyphWidth) + segHitPadX * 2
    }

    /// Full model of one path level: segment button + the drill-down chevron after it
    private struct Level {
        let url: URL
        let fullTitle: String
        let button: SegmentButton
        let chevron: ChevronButton
    }
    private var levels: [Level] = []
    private let ellipsis = EllipsisButton()

    private(set) var url: URL = FileManager.default.homeDirectoryForCurrentUser

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        ellipsis.onPick = { [weak self] target in self?.onNavigate?(target) }
        ellipsis.isHidden = true
        addSubview(ellipsis)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    func setURL(_ url: URL) {
        self.url = url
        rebuildLevels()
        needsLayout = true
    }

    /// Clicking blank space enters edit mode (QSpace convention)
    override func mouseDown(with event: NSEvent) {
        onBeginEditing?()
    }

    // MARK: Segment model construction (on URL change)

    private func rebuildLevels() {
        for lvl in levels { lvl.button.removeFromSuperview(); lvl.chevron.removeFromSuperview() }
        levels.removeAll()

        // Build forward from path components (never loop upward with deletingLastPathComponent:
        // macOS returns "/.." for "/", which does not equal itself, causing an infinite loop and memory blowup)
        var components: [URL] = [URL(fileURLWithPath: "/")]
        var cursor = URL(fileURLWithPath: "/")
        for part in url.standardizedFileURL.path.split(separator: "/") {
            cursor.appendPathComponent(String(part))
            components.append(cursor)
        }

        for (index, segURL) in components.enumerated() {
            let full = index == 0 ? "/" : segURL.lastPathComponent
            let display = Self.truncatedMiddle(full, max: Self.maxSegmentChars)
            let button = SegmentButton(displayTitle: display, fullTitle: full, url: segURL)
            button.onClick = { [weak self] in self?.onNavigate?(segURL) }
            button.onDropFiles = { [weak self] urls, target, forceCopy in
                self?.onDropFiles?(urls, target, forceCopy)
            }
            let chevron = ChevronButton(parentURL: segURL)
            chevron.onPick = { [weak self] child in self?.onNavigate?(child) }
            addSubview(button)
            addSubview(chevron)
            levels.append(Level(url: segURL, fullTitle: full, button: button, chevron: chevron))
        }
    }

    /// Middle truncation: a segment name over max characters keeps its head and tail, with "…" in between ("a-very-long…folder-name").
    private static func truncatedMiddle(_ s: String, max: Int) -> String {
        let chars = Array(s)
        guard chars.count > max else { return s }
        let keep = max - 1                    // leaves room for "…"
        let head = (keep + 1) / 2
        let tail = keep - head
        return String(chars.prefix(head)) + "…" + String(chars.suffix(tail))
    }

    // MARK: Adaptive width reflow (resize / layout switches / URL changes all pass through here)

    /// Right edge of content from the last layout (for the self-test "no overflow" assertion: should be ≤ bounds.width)
    private(set) var lastContentRight: CGFloat = 0
    /// Middle levels collapsed in the last layout (for the "…" menu and self-tests; excludes the root and visible trailing segments)
    private(set) var collapsedURLs: [URL] = []

    override func layout() {
        super.layout()
        guard !levels.isEmpty else { lastContentRight = 0; collapsedURLs = []; return }

        let h = bounds.height
        let leftInset = Self.edgeInset
        let rightInset = Self.edgeInset
        let avail = bounds.width - leftInset - rightInset
        let chevW = Self.chevronWidth

        func segW(_ i: Int) -> CGFloat { Self.segmentHitWidth(glyphWidth: levels[i].button.intrinsicContentSize.width) }
        // Each level takes segment width + the chevron after it
        func levelW(_ i: Int) -> CGFloat { segW(i) + chevW }

        let n = levels.count
        var fullWidth: CGFloat = 0
        for i in 0..<n { fullWidth += levelW(i) }

        // Everything fits -> lay out in sequence and hide "…"
        if fullWidth <= avail {
            ellipsis.isHidden = true
            collapsedURLs = []
            var x = leftInset
            for i in 0..<n {
                place(levels[i].button, at: &x, width: segW(i), height: h)
                place(levels[i].chevron, at: &x, width: chevW, height: h)
            }
            for lvl in levels { lvl.button.isHidden = false; lvl.chevron.isHidden = false }
            lastContentRight = x
            return
        }

        // Must collapse: the root stays; greedily keep as many trailing levels as possible; the middle goes into the "…" segment.
        ellipsis.configure()
        let ellW = max(20, ellipsis.intrinsicContentSize.width)

        // Decide the visible tail start tailStart (levels[tailStart ..< n] are all visible)
        // Budget = root (+chevron) + "…" segment + each trailing level
        let rootCost = levelW(0)
        var tailStart = n - 1
        var tailCost = levelW(n - 1)
        // Keep at least the last segment; then reclaim backward from the second-to-last, including each only if it fits (and without eating the root's slot)
        var i = n - 2
        while i >= 1 {
            let cost = levelW(i)
            if rootCost + ellW + tailCost + cost <= avail {
                tailCost += cost
                tailStart = i
                i -= 1
            } else {
                break
            }
        }

        // Placement: root -> "…" -> trailing segments
        var x = leftInset
        // Hide everything first, then explicitly light up the ones being placed
        for lvl in levels { lvl.button.isHidden = true; lvl.chevron.isHidden = true }

        // "Must fit" floor (a regression measured with the real layout() during adversarial review):
        // the **seed** of root + "…" + the forced-visible last segment may itself not fit (narrow pane + long last name).
        // The old version laid it out unconditionally, so lastContentRight passed bounds.width and broke the I-37 "no overflow" invariant.
        // Adding 2×segHitPadX to segment widths raises this threshold, so the floor has to be enforced:
        //     1. seed does not fit -> fold the root into "…" too (I-37's "every level stays reachable" is covered by the menu; no level is lost)
        //     2. clamp each item to the remaining budget -> x structurally cannot pass leftInset + avail
        var remaining = avail
        func placeClamped(_ v: NSView, desired: CGFloat) -> Bool {
            guard remaining > 0 else { return false }
            let w = min(desired, remaining)
            place(v, at: &x, width: w, height: h)
            remaining -= w
            return true
        }

        let seedFits = rootCost + ellW + levelW(n - 1) <= avail
        var collapsed: [URL] = []

        if seedFits {
            _ = placeClamped(levels[0].button, desired: segW(0))
            levels[0].button.isHidden = false
            _ = placeClamped(levels[0].chevron, desired: chevW)
            levels[0].chevron.isHidden = false
            collapsed = (1..<tailStart).map { levels[$0].url }
        } else {
            // Even the root does not fit: it goes into the collapsed menu (root included, still reachable)
            collapsed = (0..<max(1, n - 1)).map { levels[$0].url }
        }

        collapsedURLs = collapsed
        ellipsis.collapsedURLs = collapsed
        // When even "…" does not fit it must really be hidden: otherwise a "visible but unplaced" stale frame remains,
        // which is both a ghost hit area and makes uiTestHasEllipsis lie
        ellipsis.isHidden = !placeClamped(ellipsis, desired: ellW)

        let visibleTailStart = seedFits ? tailStart : n - 1
        for j in visibleTailStart..<n {
            guard placeClamped(levels[j].button, desired: segW(j)) else { break }
            levels[j].button.isHidden = false
            if placeClamped(levels[j].chevron, desired: chevW) {
                levels[j].chevron.isHidden = false
            }
        }
        lastContentRight = x
    }

    /// Places a subview: **the frame is the hit box**, taking the full height of the bar (the cell draws the glyph centered).
    ///
    /// Cautionary tale (user-reported bug, v0.19.17): the old version shrank the frame height to intrinsicContentSize.height
    /// and centered it vertically, so in a 20pt bar segment buttons were only 14pt and chevrons 6.5pt, with dead zones above and below.
    /// A click in a dead zone fell through to this view's mouseDown -> onBeginEditing, which the user saw as
    /// "you must hit the exact center of a folder to jump; slightly off goes into input mode".
    /// Measured dead zone share: segment 6/20=30% (42% on a 24pt address row), chevron 13.5/20=68%.
    private func place(_ v: NSView, at x: inout CGFloat, width: CGFloat, height: CGFloat) {
        v.frame = NSRect(x: x, y: 0, width: width, height: height)
        x += width
    }

    // MARK: Self-test channel (NSPACE_UITEST; I-37)

    /// Right edge of content (including left inset), should be ≤ bounds.width (no overflow)
    var uiTestContentRight: CGFloat { lastContentRight }
    /// Whether the "…" collapsed segment exists
    var uiTestHasEllipsis: Bool { !ellipsis.isHidden }
    /// URLs of the collapsed middle levels (source of the "…" menu)
    var uiTestCollapsedURLs: [URL] { collapsedURLs }
    /// Really builds the "…" menu (same builder as the click popup); returns nil with nothing collapsed
    func uiTestEllipsisMenu() -> NSMenu? {
        guard !ellipsis.isHidden else { return nil }
        return ellipsis.buildMenu()
    }
    /// toolTip of the currently visible last segment (the current directory segment; should == the full name)
    var uiTestLastSegmentToolTip: String? { levels.last?.button.toolTip }
    /// Full name of the currently visible last segment
    var uiTestLastSegmentFullName: String? { levels.last?.fullTitle }

    // ---- Hit box probe (user report "must click dead center to jump") ----
    // Assertions must target the **hit area**, not the frame: a frame-only assertion still computes the right numbers
    // with place() reverted to a short centered box, and cannot detect "can't click it". So this goes through the
    // NSView.hitTest(_:) that AppKit itself uses to dispatch mouseDown, instead of re-creating it.

    /// What kind of node hitTest landed on
    enum HitKind: String { case segment, chevron, ellipsis, bar, none }

    /// Does a **real** hitTest at a point in the bar's own coordinates.
    /// hitTest(_:) takes coordinates in the receiver's superview, so convert up first.
    func uiTestHitKind(at p: NSPoint) -> HitKind {
        guard let sp = superview else { return .none }
        let v = hitTest(convert(p, to: sp))
        if v === self { return .bar }
        if v is SegmentButton { return .segment }
        if v is ChevronButton { return .chevron }
        if v is EllipsisButton { return .ellipsis }
        return v == nil ? .none : .bar
    }

    /// If the hit point is on a segment button, fires its real action and reports that segment's URL; otherwise returns nil.
    /// Calls the action directly rather than synthesizing mouse events: NSCell.trackMouse starts a nested event loop, which hangs headless.
    func uiTestActivateSegment(at p: NSPoint) -> URL? {
        guard let sp = superview,
              let b = hitTest(convert(p, to: sp)) as? SegmentButton else { return nil }
        _ = b.target?.perform(b.action, with: b)
        return b.url
    }

    /// (URL, frame) of the visible segments (bar local coordinates)
    var uiTestVisibleSegments: [(url: URL, frame: NSRect)] {
        levels.filter { !$0.button.isHidden }.map { ($0.url, $0.button.frame) }
    }
    /// Frames of the visible chevrons (bar local coordinates)
    var uiTestVisibleChevronFrames: [NSRect] {
        levels.filter { !$0.chevron.isHidden }.map { $0.chevron.frame }
    }
    /// Glyph width (intrinsic) of the visible last segment, used to verify "hit width == glyph width + 2×padX"
    var uiTestLastSegmentGlyphWidth: CGFloat? {
        levels.last(where: { !$0.button.isHidden })?.button.intrinsicContentSize.width
    }
    /// Total left and right margin of the segment hit box (self-test and product use one source)
    static var uiTestSegHitPadTotal: CGFloat { segHitPadX * 2 }
}

/// Path segment button: click to navigate + file drop target (dragging files onto a segment = dropping into that ancestor directory)
@MainActor
private final class SegmentButton: NSButton {
    let url: URL
    var onClick: (() -> Void)?
    /// Drop callback: (urls, this segment's directory, ⌥ force copy)
    var onDropFiles: ((_ urls: [URL], _ target: URL, _ forceCopy: Bool) -> Void)?

    init(displayTitle: String, fullTitle: String, url: URL) {
        self.url = url
        super.init(frame: .zero)
        self.title = displayTitle
        self.toolTip = fullTitle          // I-37: the full name goes in the toolTip (hover a truncated segment to see it)
        bezelStyle = .accessoryBarAction
        isBordered = false
        font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        contentTintColor = .labelColor
        target = self
        action = #selector(clicked)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        wantsLayer = true
        dropHighlight.cornerRadius = 4
        dropHighlight.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(dropHighlight)
        registerForDraggedTypes([.fileURL])
    }

    /// Drop highlight layer: **decoupled** from the hit box. The hit box fills the bar's full height (else there are dead zones above and below),
    /// but the highlight must not fill it too, or it reaches the address row's edges and looks like a color block.
    /// The highlight spans the hit box **width** (= glyph + 2×segHitPadX, the same width as the area that really accepts drops,
    /// deliberately: the highlight should show "which segment a drop here lands on"), inset 2pt top and bottom to clear the address row's edges.
    private let dropHighlight = CALayer()
    /// Top/bottom inset of the highlight relative to the hit box (≤2pt optical correction tier, grid-lint exempt)
    private static let dropHighlightInsetY: CGFloat = 2

    override func layout() {
        super.layout()
        dropHighlight.frame = bounds.insetBy(dx: 0, dy: Self.dropHighlightInsetY)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    @objc private func clicked() { onClick?() }

    // MARK: Drop target (same semantics as the list: move within a volume, copy across volumes, ⌥ copies)

    private func dragOperation(_ info: any NSDraggingInfo) -> NSDragOperation {
        guard let urls = info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return [] }
        // Reject dropping a directory into itself or a descendant
        guard urls.allSatisfy({ !FileOpsCoordinator.isSelfOrDescendant(destination: url, ofSource: $0) }) else {
            return []
        }
        let forceCopy = info.draggingSourceOperationMask == .copy
        // All sources are already in this segment's directory: a move is a no-op -> reject (⌥ copy is allowed)
        let destPath = url.standardizedFileURL.path
        if !forceCopy, urls.allSatisfy({ $0.standardizedFileURL.deletingLastPathComponent().path == destPath }) {
            return []
        }
        if forceCopy { return .copy }
        return urls.allSatisfy({ FileOpsCoordinator.isSameVolume($0, url) }) ? .move : .copy
    }

    private func setDropHighlight(_ on: Bool) {
        dropHighlight.backgroundColor = on
            ? Theme.accent.withAlphaComponent(0.10).cgColor
            : NSColor.clear.cgColor
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let op = dragOperation(sender)
        setDropHighlight(op != [])
        return op
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dragOperation(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        setDropHighlight(false)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        setDropHighlight(false)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dragOperation(sender) != []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        setDropHighlight(false)
        guard let urls = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        onDropFiles?(urls, url, sender.draggingSourceOperationMask == .copy)
        return true
    }
}

/// Arrow between segments: click to pop up that level's subfolder menu (built lazily)
@MainActor
private final class ChevronButton: NSButton {
    let parentURL: URL
    var onPick: ((URL) -> Void)?

    init(parentURL: URL) {
        self.parentURL = parentURL
        super.init(frame: .zero)
        title = ""
        image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: L10n.t("addressbar.subfolders"))
        symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        contentTintColor = .tertiaryLabelColor
        isBordered = false
        target = self
        action = #selector(showMenu)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    @objc private func showMenu() {
        let menu = NSMenu()
        let fm = FileManager.default
        let children = (try? fm.contentsOfDirectory(at: parentURL,
                                                    includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                    options: [.skipsHiddenFiles])) ?? []
        let dirs = children
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]))
                .map { ($0.isDirectory ?? false) && !($0.isPackage ?? false) } ?? false }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        if dirs.isEmpty {
            let item = menu.addItem(withTitle: L10n.t("addressbar.noSubfolders"), action: nil, keyEquivalent: "")
            item.isEnabled = false
        }
        for dir in dirs {
            let item = menu.addItem(withTitle: dir.lastPathComponent, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = dir
            item.image = NSWorkspace.shared.icon(for: .folder)
            item.image?.size = NSSize(width: 14, height: 14)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 2), in: self)
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onPick?(url)
    }
}

/// Collapsed "…" segment: stands for the hidden middle levels; click pops up a menu listing all collapsed levels (indented by depth), and picking one navigates there.
/// Guarantees "deep levels are always reachable": however narrow the pane, all ancestors are in this menu.
@MainActor
private final class EllipsisButton: NSButton {
    var onPick: ((URL) -> Void)?
    var collapsedURLs: [URL] = []

    init() {
        super.init(frame: .zero)
        isBordered = false
        contentTintColor = .secondaryLabelColor
        target = self
        action = #selector(showMenu)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    /// Official ellipsis symbol, falling back to plain text "…" if unavailable (§6.1 official symbol hard rule + fallback)
    func configure() {
        if let img = NSImage.officialSymbol("ellipsis",
                                            accessibility: L10n.t("addressbar.collapsedLevels")) {
            image = img
            symbolConfiguration = .init(pointSize: 11, weight: .semibold)
            title = ""
        } else {
            image = nil
            title = "…"
            font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        }
        toolTip = L10n.t("addressbar.collapsedLevels")
    }

    /// Builds the collapsed levels menu (shared by the click popup and self-tests): in path order, indented by depth; picking an item navigates.
    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        if collapsedURLs.isEmpty {
            let item = menu.addItem(withTitle: L10n.t("addressbar.noSubfolders"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            return menu
        }
        for (i, dir) in collapsedURLs.enumerated() {
            let item = menu.addItem(withTitle: dir.lastPathComponent,
                                    action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = dir
            item.indentationLevel = i          // depth indent (deeper paths indent more)
            item.image = NSWorkspace.shared.icon(for: .folder)
            item.image?.size = NSSize(width: 14, height: 14)
        }
        return menu
    }

    @objc private func showMenu() {
        buildMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 2), in: self)
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onPick?(url)
    }
}
