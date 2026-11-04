import AppKit
import SessionStore

/// Pane layout (v1 subset of QSpace's 12 layouts)
enum PaneLayout: Int, CaseIterable {
    case single = 1     // single pane
    case dualH          // two columns (left/right)
    case dualV          // two rows (top/bottom)
    case tripleH        // three columns
    case quad           // quad

    var paneCount: Int {
        switch self {
        case .single: 1
        case .dualH, .dualV: 2
        case .tripleH: 3
        case .quad: 4
        }
    }

    /// L10n name key (shared by menus/settings window/registry so keys do not scatter)
    var titleKey: String {
        switch self {
        case .single: "layout.single"
        case .dualH: "layout.dualH"
        case .dualV: "layout.dualV"
        case .tripleH: "layout.tripleH"
        case .quad: "layout.quad"
        }
    }

    var localizedName: String { L10n.t(titleKey) }

    var symbolName: String {
        switch self {
        case .single: "rectangle"
        case .dualH: "rectangle.split.2x1"
        case .dualV: "rectangle.split.1x2"
        case .tripleH: "rectangle.split.3x1"
        case .quad: "rectangle.split.2x2"
        }
    }
}

/// Pane grid + focus coordination: lazily built pane pool, layout switches keep state, Tab cycles focus, active pane highlight.
/// Panes switched away are hidden, not destroyed (browsing context/history/scroll position all stay)
@MainActor
final class PaneGridController: NSViewController {
    private(set) var layout: PaneLayout = .single
    /// Pane pool: at most 4, created lazily, not destroyed on layout switches
    private var pool: [PaneViewController] = []
    private(set) var activePaneIndex = 0
    private let initialDirectory: URL

    /// File operations bridge (injected by MainWindowController and passed down to each pane)
    var coordinator: FileOpsCoordinator? {
        didSet { pool.forEach { $0.coordinator = coordinator } }
    }

    var onActiveLocationChange: ((URL) -> Void)?
    /// Active pane count/selection changes propagate up (re-validates deck action buttons' enabled state; M17)
    var onActiveStatusChange: (() -> Void)?

    var activePane: PaneViewController { pool[activePaneIndex] }
    var visiblePanes: [PaneViewController] { Array(pool.prefix(layout.paneCount)) }

    init(initialDirectory: URL) {
        self.initialDirectory = initialDirectory
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    override func loadView() {
        view = NSView()
        ensurePanes(count: layout.paneCount)
        rebuildGrid()
    }

    // MARK: Layout switching (⌃⌘1..5 / toolbar)

    func apply(layout newLayout: PaneLayout) {
        guard newLayout != layout else { return }
        layout = newLayout
        ensurePanes(count: layout.paneCount)
        // North star: panes switched away by the layout are fully suspended (watchers really stop); panes switched back resume (reload only if mtime changed)
        for (i, pane) in pool.enumerated() {
            if i < layout.paneCount { pane.resumePane() } else { pane.suspendPane() }
        }
        if activePaneIndex >= layout.paneCount { setActivePane(0) }
        rebuildGrid()
        // rebuildGrid does removeFromSuperview on the old hierarchy: a firstResponder inside a removed view gets
        // bounced by AppKit to the window itself (not any NSView), and the keyboard goes dead until the user clicks something.
        // Easiest to hit while the address bar is being edited (firstResponder is the field editor). Explicitly restore focus after the rebuild.
        view.window?.makeFirstResponder(activePane.focusTarget)
    }

    private func ensurePanes(count: Int) {
        while pool.count < count {
            let index = pool.count
            // A new pane opens at the active pane's current location (QSpace convention); the first opens the initial directory
            let dir = pool.isEmpty ? initialDirectory : activePane.activeTab.browser.current
            let pane = PaneViewController(directory: dir)
            pane.coordinator = coordinator
            pane.onRequestFocus = { [weak self, weak pane] in
                guard let self, let pane, let i = self.pool.firstIndex(where: { $0 === pane }) else { return }
                self.setActivePane(i)
            }
            pane.onLocationChange = { [weak self, weak pane] url in
                guard let self, let pane else { return }
                if pane === self.activePane { self.onActiveLocationChange?(url) }
            }
            pane.onStatusChange = { [weak self, weak pane] in
                guard let self, let pane else { return }
                if pane === self.activePane { self.onActiveStatusChange?() }
            }
            addChild(pane)
            pool.append(pane)
            _ = index
        }
    }

    private var currentGrid: NSView?
    private var needsEqualize = false

    private func rebuildGrid() {
        view.subviews.forEach { $0.removeFromSuperview() }
        let panes = visiblePanes.map(\.view)
        let grid: NSView
        switch layout {
        case .single:
            grid = panes[0]
        case .dualH:
            grid = makeSplit(vertical: true, panes)
        case .dualV:
            grid = makeSplit(vertical: false, panes)
        case .tripleH:
            grid = makeSplit(vertical: true, panes)
        case .quad:
            let top = makeSplit(vertical: true, [panes[0], panes[1]])
            let bottom = makeSplit(vertical: true, [panes[2], panes[3]])
            grid = makeSplit(vertical: false, [top, bottom])
        }
        grid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.topAnchor),
            grid.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        currentGrid = grid
        needsEqualize = true
        refreshActiveHighlight()
        view.needsLayout = true
    }

    /// Equalizing must run once real layout sizes are ready; keep re-equalizing until the window size settles
    /// (running it once gives all space to the last pane when the size grows later, collapsing the first row/column)
    private var lastLayoutSize: NSSize = .zero

    override func viewDidLayout() {
        super.viewDidLayout()
        guard needsEqualize, let grid = currentGrid,
              grid.bounds.height > 1, grid.bounds.width > 1 else { return }
        equalizeSplits(in: grid)
        if grid.bounds.size == lastLayoutSize {
            needsEqualize = false  // same size in two consecutive layouts = stable; hand dragging back to the user
        }
        lastLayoutSize = grid.bounds.size
    }

    private func makeSplit(vertical: Bool, _ subviews: [NSView]) -> NSSplitView {
        let split = NSSplitView()
        split.isVertical = vertical
        split.dividerStyle = .thin
        // NSSplitView distributes space by the subviews' current frame ratios; reused panes arriving with old frames
        // can collapse a row/column, so preset equal frames explicitly and the ratio is always 1/n (deterministic, no layout timing race)
        let n = CGFloat(subviews.count)
        let nominal = NSSize(width: 1200, height: 800)
        for (i, sub) in subviews.enumerated() {
            sub.translatesAutoresizingMaskIntoConstraints = true
            // [.width,.height] is mandatory: the default none turns the leftover frame into required fixed-size constraints,
            // and the constraint engine then collapses the window in reverse (the real cause of windows resizing after view/layout switches, identified by the probe)
            sub.autoresizingMask = [.width, .height]
            sub.frame = vertical
                ? NSRect(x: CGFloat(i) * nominal.width / n, y: 0,
                         width: nominal.width / n, height: nominal.height)
                : NSRect(x: 0, y: CGFloat(i) * nominal.height / n,
                         width: nominal.width, height: nominal.height / n)
            split.addArrangedSubview(sub)
        }
        split.frame = NSRect(origin: .zero, size: nominal)
        return split
    }

    private func equalizeSplits(in root: NSView) {
        guard let split = root as? NSSplitView else { return }
        let count = split.arrangedSubviews.count
        let total = split.isVertical ? split.bounds.width : split.bounds.height
        guard count > 1, total > 0 else { return }
        let each = (total - CGFloat(count - 1) * split.dividerThickness) / CGFloat(count)
        for i in 1..<count {
            split.setPosition(CGFloat(i) * (each + split.dividerThickness) - split.dividerThickness, ofDividerAt: i - 1)
        }
        for sub in split.arrangedSubviews { equalizeSplits(in: sub) }
    }

    // MARK: Focus coordination

    func setActivePane(_ index: Int) {
        guard index < layout.paneCount else { return }
        let sameAsActive = (index == activePaneIndex)
        activePaneIndex = index
        refreshActiveHighlight()                         // idempotent and cheap: must always run for multi-pane restore/first-layout tinting
        view.window?.makeFirstResponder(activePane.focusTarget)
        // Click within the same pane: do not re-push location/status. Selection changes inside a pane already update the deck through pane.onStatusChange,
        // and another push here carries the "pre-selection" stale value, causing a double-refresh stutter (I-33); only cross-pane switches need this push.
        guard !sameAsActive else { return }
        onActiveLocationChange?(activePane.activeTab.browser.current)
        onActiveStatusChange?()
    }

    private func refreshActiveHighlight() {
        // No tint for a single pane (no visual noise when nothing is ambiguous); inactive panes are dimmed only with multiple panes
        let multi = layout.paneCount > 1
        for (i, pane) in pool.enumerated() {
            let active = multi && i == activePaneIndex
            pane.setActive(active, dimmed: multi && !active)
        }
    }

    /// Refresh pane tint/dimming after appearance changes (accent/highlight toggle/dimming alpha apply at once)
    func refreshTheme() {
        refreshActiveHighlight()
    }

    /// Tab key cycles pane focus
    func cycleFocus(backward: Bool = false) {
        let count = layout.paneCount
        guard count > 1 else { return }
        let next = backward
            ? (activePaneIndex - 1 + count) % count
            : (activePaneIndex + 1) % count
        setActivePane(next)
    }


    // MARK: Session snapshot/restore (M11)

    func sessionWindow() -> SessionWindow {
        SessionWindow(layoutRaw: layout.rawValue,
                      panes: visiblePanes.map { $0.sessionPane() },
                      activePaneIndex: activePaneIndex)
    }

    func restoreSession(_ w: SessionWindow) {
        _ = view  // force loadView first (pane pool in place)
        if let l = PaneLayout(rawValue: w.layoutRaw) { apply(layout: l) }
        for (pane, sp) in zip(visiblePanes, w.panes) {
            // Target state **identical field by field** to the pane's current state -> no rebuild: keeps browsing history / selection / scroll position.
            // "New workspace = duplicate current workspace" builds its snapshot verbatim from the current state, and only the active pane may change path;
            // an unconditional installTab would replace, BrowserState included, panes the user never touched:
            // after switching back, ⌘[ stops working, the selection vanishes and the list scrolls to the top. External opens take this path by default, so it would hit every time.
            guard pane.sessionPane() != sp else { continue }
            pane.restoreSession(sp)
        }
        setActivePane(min(max(0, w.activePaneIndex), layout.paneCount - 1))
    }

    // MARK: Menu commands

    @objc func applyLayout(_ sender: NSMenuItem) {
        guard let layout = PaneLayout(rawValue: sender.tag) else { return }
        apply(layout: layout)
    }
}

extension PaneGridController: @preconcurrency NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(applyLayout(_:)) {
            menuItem.state = menuItem.tag == layout.rawValue ? .on : .off
        }
        return true
    }
}
