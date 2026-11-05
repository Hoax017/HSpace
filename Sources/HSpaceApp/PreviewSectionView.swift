import AppKit
import HSpaceContracts
import QuickLookUI
import SidePanel

/// One action the panel can offer. Every selector exists on all three content views, so an action means the same in each view mode.
struct PanelAction {
    let id: String
    let titleKey: String
    let symbol: String
    let selector: Selector

    @MainActor static let all: [PanelAction] = [
        PanelAction(id: "open", titleKey: "menu.open", symbol: "arrow.up.forward.app",
                    selector: #selector(FileListViewController.openSelected(_:))),
        PanelAction(id: "quickLook", titleKey: "menu.quickLook", symbol: "eye",
                    selector: #selector(FileListViewController.toggleQuickLook(_:))),
        PanelAction(id: "getInfo", titleKey: "menu.getInfo", symbol: "info.circle",
                    selector: #selector(FileListViewController.getInfo(_:))),
        PanelAction(id: "copyPath", titleKey: "menu.copyPath", symbol: "link",
                    selector: #selector(FileListViewController.copyPath(_:))),
        PanelAction(id: "editTags", titleKey: "menu.editTags", symbol: "tag",
                    selector: #selector(FileListViewController.editTags(_:))),
        PanelAction(id: "editComment", titleKey: "menu.editComment", symbol: "text.bubble",
                    selector: #selector(FileListViewController.editComment(_:))),
        PanelAction(id: "duplicate", titleKey: "menu.duplicate", symbol: "plus.square.on.square",
                    selector: #selector(FileListViewController.duplicateItems(_:))),
        PanelAction(id: "copyToOtherPane", titleKey: "menu.copyToOtherPane", symbol: "doc.on.doc",
                    selector: #selector(FileListViewController.copyToOtherPane(_:))),
        PanelAction(id: "moveToOtherPane", titleKey: "menu.moveToOtherPane", symbol: "arrow.right.doc.on.clipboard",
                    selector: #selector(FileListViewController.moveToOtherPane(_:))),
        PanelAction(id: "moveToTrash", titleKey: "menu.moveToTrash", symbol: "trash",
                    selector: #selector(FileListViewController.moveToTrash(_:))),
    ]

    static let defaultIDs = ["open", "quickLook", "copyPath", "moveToTrash"]

    @MainActor static func action(_ id: String) -> PanelAction? { all.first { $0.id == id } }

    @MainActor static func list() -> PanelActionList {
        PanelActionList(stored: Preferences.panelActions, known: all.map(\.id), defaults: defaultIDs)
    }
}

/// Preview of the selection, its name, and the owner's actions. QLPreviewView does the drawing, so anything Quick Look can show works here.
/// It does not autostart, so a video sits still until the user presses play.
@MainActor
final class PreviewSectionView: NSView {
    var onAction: ((String) -> Void)?

    /// Built on first use: a hidden panel costs nothing
    private var preview: QLPreviewView?
    private let previewArea = NSView()
    private let message = ToolUI.label("", size: 11, color: .tertiaryLabelColor)
    private let name = NSTextField(labelWithString: "")
    private let actions = ActionFlowView()
    private var subject: PreviewSubject?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        message.alignment = .center
        message.lineBreakMode = .byWordWrapping
        message.maximumNumberOfLines = 0
        name.font = .systemFont(ofSize: 12)
        name.alignment = .center
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        actions.onAction = { [weak self] id in self?.onAction?(id) }
        for sub in [previewArea, message, name, actions] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
        }
        NSLayoutConstraint.activate([
            previewArea.topAnchor.constraint(equalTo: topAnchor),
            previewArea.leadingAnchor.constraint(equalTo: leadingAnchor),
            previewArea.trailingAnchor.constraint(equalTo: trailingAnchor),
            message.centerYAnchor.constraint(equalTo: previewArea.centerYAnchor),
            message.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            message.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            name.topAnchor.constraint(equalTo: previewArea.bottomAnchor, constant: 4),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            actions.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 4),
            actions.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            actions.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        rebuildActions()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    func show(_ subject: PreviewSubject) {
        guard subject != self.subject else { return }
        self.subject = subject
        switch subject {
        case .nothing:
            setPreviewItem(nil)
            present(message: L10n.t("panel.preview.nothing"), name: "")
        case .item(let url, let title):
            setPreviewItem(url)
            present(message: nil, name: title)
        case .several(let count, let folders, let bytes):
            setPreviewItem(nil)
            let size = bytes > 0 ? Formatters.size.string(fromByteCount: bytes) : nil
            present(message: Self.summary(count: count, folders: folders, size: size), name: "")
        }
    }

    /// `size` covers files only, and the text says so when folders are selected too, so a folder's weight is not implied
    static func summary(count: Int, folders: Int, size: String?) -> String {
        guard let size else { return L10n.f("panel.preview.count", count) }
        return L10n.f(folders > 0 ? "panel.preview.countFilesSize" : "panel.preview.countSize", count, size)
    }

    private func present(message text: String?, name title: String) {
        message.stringValue = text ?? ""
        message.isHidden = text == nil
        preview?.isHidden = text != nil
        name.stringValue = title
    }

    private func setPreviewItem(_ url: URL?) {
        if url != nil, preview == nil { buildPreview() }
        preview?.previewItem = url as NSURL?
    }

    private func buildPreview() {
        guard let view = QLPreviewView(frame: previewArea.bounds, style: .compact) else { return }
        view.autostarts = false
        view.shouldCloseWithWindow = false
        view.autoresizingMask = [.width, .height]
        previewArea.addSubview(view)
        preview = view
    }

    /// The panel was hidden: lets go of the file, and stops any media
    func clear() {
        preview?.previewItem = nil
        subject = nil
    }

    func close() {
        preview?.close()
        preview = nil
        subject = nil
    }

    func rebuildActions() {
        actions.show(PanelAction.list().enabled.compactMap(PanelAction.action))
    }

    func setAvailability(_ available: (PanelAction) -> Bool) {
        actions.setAvailability(available)
    }

    var testMessage: String { message.isHidden ? "" : message.stringValue }
    var testName: String { name.stringValue }
    var testActionIDs: [String] { actions.ids }
}

/// Icon buttons that wrap onto as many rows as the panel's width needs
@MainActor
final class ActionFlowView: NSView {
    var onAction: ((String) -> Void)?
    private var entries: [(action: PanelAction, button: NSButton)] = []
    private static let side: CGFloat = 24
    private static let gap: CGFloat = 4

    var ids: [String] { entries.map(\.action.id) }

    override var isFlipped: Bool { true }

    func show(_ list: [PanelAction]) {
        entries.forEach { $0.button.removeFromSuperview() }
        entries = list.map { action in
            let title = L10n.t(action.titleKey)
            let button = NSButton(image: NSImage(systemSymbolName: action.symbol, accessibilityDescription: title) ?? NSImage(),
                                  target: self, action: #selector(clicked(_:)))
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = title
            button.setAccessibilityLabel(title)
            button.identifier = NSUserInterfaceItemIdentifier(action.id)
            addSubview(button)
            return (action, button)
        }
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    func setAvailability(_ available: (PanelAction) -> Bool) {
        for entry in entries { entry.button.isEnabled = available(entry.action) }
    }

    @objc private func clicked(_ sender: NSButton) {
        if let id = sender.identifier?.rawValue { onAction?(id) }
    }

    /// Buttons per row at a width
    static func perRow(width: CGFloat) -> Int {
        max(1, Int((width + gap) / (side + gap)))
    }

    static func height(count: Int, width: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        let columns = perRow(width: width)
        let rows = CGFloat((count + columns - 1) / columns)
        return rows * side + (rows - 1) * gap
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height(count: entries.count, width: bounds.width))
    }

    override func layout() {
        super.layout()
        let columns = Self.perRow(width: bounds.width)
        let step = Self.side + Self.gap
        // Centred, the way the name above is
        let rowWidth = CGFloat(min(columns, entries.count)) * step - Self.gap
        let left = max(0, (bounds.width - rowWidth) / 2)
        for (index, entry) in entries.enumerated() {
            entry.button.frame = NSRect(x: left + CGFloat(index % columns) * step, y: CGFloat(index / columns) * step,
                                        width: Self.side, height: Self.side)
        }
        invalidateIntrinsicContentSize()
    }
}
