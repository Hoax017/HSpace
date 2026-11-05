import AppKit
import HSpaceContracts
import SidePanel

/// What the side panel needs from the active pane
struct DetailSource {
    let directory: URL
    let selection: [FileItem]
    let pane: PaneViewController
}

/// The window's right-hand column: the preview, and below it the inspector. Each is shown on its own.
/// While both are hidden the column has no width and does no work.
/// Selections arrive in bursts (arrow key held down), so updates are coalesced and only the last one loads anything.
@MainActor
final class DetailPanelController: NSViewController {
    /// Reads the active pane when an update is due, so a stale selection is never shown
    var source: (() -> DetailSource?)?

    private let handle = PanelResizeHandle()
    private let previewSection = PreviewSectionView()
    private let inspectorSection = InspectorSectionView()
    private let inspectorRule = NSBox()
    /// One of three arrangements, by which sections show
    private var previewFills: NSLayoutConstraint!
    private var previewHalf: NSLayoutConstraint!
    private var inspectorBelowPreview: NSLayoutConstraint!
    private var inspectorFills: NSLayoutConstraint!
    private var width: NSLayoutConstraint!
    private var pendingUpdate: DispatchWorkItem?

    private(set) var previewVisible = Preferences.previewPanelVisible
    private(set) var inspectorVisible = Preferences.inspectorPanelVisible

    private var isShowing: Bool { previewVisible || inspectorVisible }

    override func loadView() {
        let root = NSView()
        handle.onDrag = { [weak self] delta in self?.resize(by: delta) }
        handle.onDragEnd = { [weak self] in
            guard let self else { return }
            Preferences.detailPanelWidth = self.width.constant
        }
        previewSection.onAction = { [weak self] id in self?.perform(id) }
        inspectorRule.boxType = .separator
        for sub in [handle, previewSection, inspectorRule, inspectorSection] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(sub)
        }
        width = root.widthAnchor.constraint(equalToConstant: 0)
        previewFills = previewSection.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        previewHalf = previewSection.heightAnchor.constraint(equalTo: root.heightAnchor, multiplier: 0.5)
        inspectorBelowPreview = inspectorRule.topAnchor.constraint(equalTo: previewSection.bottomAnchor)
        inspectorFills = inspectorRule.topAnchor.constraint(equalTo: root.topAnchor)
        NSLayoutConstraint.activate([
            width,
            handle.topAnchor.constraint(equalTo: root.topAnchor),
            handle.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            handle.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            handle.widthAnchor.constraint(equalToConstant: 4),
            previewSection.topAnchor.constraint(equalTo: root.topAnchor),
            previewSection.leadingAnchor.constraint(equalTo: handle.trailingAnchor),
            previewSection.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            inspectorRule.leadingAnchor.constraint(equalTo: handle.trailingAnchor),
            inspectorRule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            inspectorSection.topAnchor.constraint(equalTo: inspectorRule.bottomAnchor),
            inspectorSection.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            inspectorSection.leadingAnchor.constraint(equalTo: handle.trailingAnchor),
            inspectorSection.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        view = root
        root.clipsToBounds = true
        NotificationCenter.default.addObserver(self, selector: #selector(actionsChanged(_:)),
                                               name: .hspacePanelActionsChanged, object: nil)
        applyVisibility()
    }

    func setPreview(visible: Bool) {
        previewVisible = visible
        Preferences.previewPanelVisible = visible
        applyVisibility()
    }

    func setInspector(visible: Bool) {
        inspectorVisible = visible
        Preferences.inspectorPanelVisible = visible
        applyVisibility()
    }

    private func applyVisibility() {
        guard isViewLoaded else { return }
        let both = previewVisible && inspectorVisible
        NSLayoutConstraint.deactivate([previewFills, previewHalf, inspectorBelowPreview, inspectorFills])
        NSLayoutConstraint.activate(both ? [previewHalf, inspectorBelowPreview]
                                         : previewVisible ? [previewFills] : [inspectorFills])
        inspectorSection.isHidden = !inspectorVisible
        inspectorRule.isHidden = !both
        if !inspectorVisible { inspectorSection.clear() }
        width.constant = isShowing ? SidePanelWidth.clamped(Preferences.detailPanelWidth) : 0
        handle.isHidden = !isShowing
        previewSection.isHidden = !previewVisible
        if !previewVisible { previewSection.clear() }
        updateNow()
    }

    /// The selection, the active pane or its folder may have changed
    func noteSelectionChanged() {
        guard isViewLoaded, isShowing else { return }
        pendingUpdate?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.updateNow() }
        pendingUpdate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func updateNow() {
        pendingUpdate = nil
        guard isShowing, let source = source?() else { return }
        if previewVisible {
            previewSection.show(PreviewSubject(selection: source.selection))
            refreshActionAvailability(source.pane)
        }
        if inspectorVisible { inspectorSection.show(selection: source.selection, directory: source.directory) }
    }

    private func refreshActionAvailability(_ pane: PaneViewController) {
        previewSection.setAvailability { pane.canPerformContentAction($0.selector) }
    }

    private func perform(_ id: String) {
        guard let action = PanelAction.action(id), let pane = source?()?.pane else { return }
        pane.performContentAction(action.selector, from: self)
    }

    private func resize(by delta: CGFloat) {
        width.constant = SidePanelWidth.clamped(width.constant - delta)
    }

    @objc private func actionsChanged(_ note: Notification) {
        previewSection.rebuildActions()
        if let pane = source?()?.pane { refreshActionAvailability(pane) }
    }

    /// Called when the window goes, so that a preview does not outlive it
    func teardown() {
        pendingUpdate?.cancel()
        NotificationCenter.default.removeObserver(self)
        previewSection.close()
        inspectorSection.clear()
    }

    // MARK: Test channel
    var testPreviewSection: PreviewSectionView { previewSection }
}

/// Dragging its edge resizes the panel. One hairline wide to the eye, 4pt wide to the pointer.
@MainActor
final class PanelResizeHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?
    private var lastX: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func mouseDown(with event: NSEvent) { lastX = event.locationInWindow.x }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.locationInWindow.x - lastX)
        lastX = event.locationInWindow.x
    }

    override func mouseUp(with event: NSEvent) { onDragEnd?() }
}

extension Notification.Name {
    /// The owner changed which actions the side panel offers
    static let hspacePanelActionsChanged = Notification.Name("hspacePanelActionsChanged")
}
