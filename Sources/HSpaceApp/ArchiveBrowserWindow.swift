import AppKit
import ArchiveEngine
import HSpaceContracts
import Quartz
import UniformTypeIdentifiers

/// Shows what an archive holds, without extracting it. A window of its own, because panes show real folders only
/// until the virtual file system of phase 2 exists.
@MainActor
final class ArchiveBrowserWindowController: NSWindowController, NSWindowDelegate {
    private(set) static var open: [ArchiveBrowserWindowController] = []

    static func show(archive: URL, coordinator: FileOpsCoordinator?) {
        if let existing = open.first(where: { $0.model.archive == archive }) {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = ArchiveBrowserWindowController(archive: archive, coordinator: coordinator)
        open.append(controller)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        controller.reload()
    }

    let model: ArchiveBrowserModel
    private weak var coordinator: FileOpsCoordinator?
    private let outline = ArchiveOutlineView()
    private let status = ToolUI.label()
    private let spinner = NSProgressIndicator()
    private let cancelButton = ToolUI.button(L10n.t("archive.cancel"), target: nil, action: nil)
    private let extractButton = ToolUI.button(L10n.t("menu.extractTo"), target: nil, action: nil)
    private let previewButton = ToolUI.button(L10n.t("menu.quickLook"), target: nil, action: nil)
    private var work: Task<Void, Never>?
    private var icons: [String: NSImage] = [:]
    /// What the Quick Look panel shows
    private(set) var previewItems: [URL] = []
    private var controlsPreviewPanel = false

    private enum Column {
        static let name = NSUserInterfaceItemIdentifier("name")
        static let size = NSUserInterfaceItemIdentifier("size")
        static let modified = NSUserInterfaceItemIdentifier("modified")
    }

    init(archive: URL, coordinator: FileOpsCoordinator?) {
        self.model = ArchiveBrowserModel(archive: archive)
        self.coordinator = coordinator
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = archive.lastPathComponent
        window.representedURL = archive
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 400, height: 240)
        super.init(window: window)
        window.delegate = self
        buildContent(in: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func buildContent(in window: NSWindow) {
        let columns: [(NSUserInterfaceItemIdentifier, String, CGFloat)] = [
            (Column.name, "archive.column.name", 340), (Column.size, "archive.column.size", 80),
            (Column.modified, "archive.column.modified", 160),
        ]
        for (identifier, titleKey, width) in columns {
            let column = NSTableColumn(identifier: identifier)
            column.title = L10n.t(titleKey)
            column.width = width
            outline.addTableColumn(column)
        }
        outline.outlineTableColumn = outline.tableColumns[0]
        outline.dataSource = self
        outline.delegate = self
        outline.allowsMultipleSelection = true
        outline.usesAlternatingRowBackgroundColors = true
        outline.setAccessibilityLabel(L10n.f("archive.accessibility.contents", model.archive.lastPathComponent))
        outline.target = self
        outline.doubleAction = #selector(openRow(_:))

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        cancelButton.target = self
        cancelButton.action = #selector(cancelWork(_:))
        cancelButton.isHidden = true
        extractButton.target = self
        extractButton.action = #selector(extractTo(_:))
        extractButton.toolTip = L10n.t("archive.extract.tooltip")

        previewButton.target = self
        previewButton.action = #selector(toggleQuickLook(_:))
        previewButton.isEnabled = false
        outline.onSpace = { [weak self] in self?.toggleQuickLook(nil) }

        let bar = NSStackView(views: [spinner, status, NSView(), cancelButton, previewButton, extractButton])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let root = NSView()
        for view in [scroll, bar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        window.contentView = root
        window.initialFirstResponder = outline
    }

    // MARK: Background work (one job at a time: Cancel and Escape stop it)

    private var isBusy: Bool { work != nil }

    private func setBusy(_ message: String?) {
        cancelButton.isHidden = message == nil
        extractButton.isEnabled = message == nil
        if let message {
            status.stringValue = message
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }

    private func begin(_ message: String, _ job: @escaping @MainActor () async throws -> Void) {
        work?.cancel()
        setBusy(message)
        work = Task { [weak self] in
            var failure: (any Error)?
            do {
                try await job()
            } catch is CancellationError {
                // Stopped on request: nothing to report
            } catch {
                failure = error
            }
            guard let self, !Task.isCancelled else { return }
            self.work = nil
            self.setBusy(nil)
            self.showCounts()
            if let failure { self.present(failure) }
        }
    }

    @objc private func cancelWork(_ sender: Any?) {
        work?.cancel()
        work = nil
        setBusy(nil)
        showCounts()
    }

    override func cancelOperation(_ sender: Any?) {
        if isBusy { cancelWork(sender) } else { window?.performClose(sender) }
    }

    private func showCounts() {
        status.stringValue = model.root == nil ? "" : L10n.f("archive.status.items", model.itemCount)
    }

    private func present(_ error: any Error) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t("archive.problem.title")
        alert.informativeText = (error as? any ClassifiedError)?.localizedDescription ?? error.localizedDescription
        alert.beginSheetModal(for: window)
    }

    // MARK: Actions

    func reload() {
        begin(L10n.t("archive.status.reading")) { [weak self] in
            try await self?.model.load()
            self?.outline.reloadData()
        }
    }

    /// Waits for the listing. Tests only.
    func waitUntilIdle() async {
        await work?.value
    }

    private var selectedNodes: [ArchiveTreeNode] {
        outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? ArchiveTreeNode }
    }

    @objc private func openRow(_ sender: Any?) {
        guard let node = outline.item(atRow: outline.clickedRow) as? ArchiveTreeNode else { return }
        guard node.isFolder else {
            showPreview()
            return
        }
        if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
    }

    // MARK: Quick Look (the file is taken out to a private temporary folder first)

    /// Same selector as the file views, so the Quick Look menu item and its shortcut reach this window too
    @objc func toggleQuickLook(_ sender: Any?) {
        if let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
        } else {
            showPreview()
        }
    }

    private func showPreview() {
        begin(L10n.t("archive.status.preparing")) { [weak self] in
            guard let self else { return }
            try await self.loadPreview()
            guard !self.previewItems.isEmpty else {
                NSSound.beep()
                return
            }
            QLPreviewPanel.shared()?.makeKeyAndOrderFront(nil)
        }
    }

    private func loadPreview() async throws {
        let urls = try await model.previewURLs(selectedNodes)
        try Task.checkCancellation()
        previewItems = urls
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        controlsPreviewPanel = true
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        controlsPreviewPanel = false
        panel.dataSource = nil
        panel.delegate = nil
    }

    /// Selected items, or the whole archive when nothing is selected
    @objc private func extractTo(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = model.archive.deletingLastPathComponent()
        panel.prompt = L10n.t("menu.extractTo.prompt")
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let directory = panel.url else { return }
                self?.extract(into: directory)
            }
        }
    }

    private func extract(into directory: URL) {
        let nodes = selectedNodes
        guard !nodes.isEmpty else {
            coordinator?.extract([model.archive], into: directory)
            return
        }
        begin(L10n.t("archive.status.extracting")) { [weak self] in
            guard let self else { return }
            let staged = try await self.model.stage(nodes)
            // Cancelled here or not, from now on Transfer owns the items: conflicts, progress and errors work as for any move
            guard !Task.isCancelled, let coordinator = self.coordinator else {
                self.model.discard(staged.scratch)
                return
            }
            coordinator.landExtracted(staged.items, into: directory) { [weak self] in
                self?.model.discard(staged.scratch)
            }
        }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        work?.cancel()
        work = nil
        if controlsPreviewPanel { QLPreviewPanel.shared()?.orderOut(nil) }
        model.discardAll()
        Self.open.removeAll { $0 === self }
    }

    // MARK: Cells

    fileprivate func icon(for node: ArchiveTreeNode) -> NSImage {
        let key = node.isFolder ? "/" : URL(fileURLWithPath: node.name).pathExtension.lowercased()
        if let cached = icons[key] { return cached }
        let type: UTType = node.isFolder ? .folder : UTType(filenameExtension: key) ?? .data
        let image = NSWorkspace.shared.icon(for: type)
        icons[key] = image
        return image
    }

    fileprivate func text(for node: ArchiveTreeNode, column: NSUserInterfaceItemIdentifier) -> String {
        switch column {
        case Column.size:
            guard !node.isFolder, let size = node.entry.size else { return "--" }
            return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        case Column.modified:
            return node.entry.modified.map { Formatters.relativeDate($0) } ?? "--"
        default:
            return node.name
        }
    }
}

extension ArchiveBrowserWindowController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? ArchiveTreeNode) ?? model.root)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let children = ((item as? ArchiveTreeNode) ?? model.root)?.children, index < children.count else {
            return NSNull()
        }
        return children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? ArchiveTreeNode)?.isFolder ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? ArchiveTreeNode, let column = tableColumn?.identifier else { return nil }
        let cell = (outlineView.makeView(withIdentifier: column, owner: self) as? ArchiveCell)
            ?? ArchiveCell(identifier: column, showsIcon: column == Column.name)
        cell.textField?.stringValue = text(for: node, column: column)
        cell.textField?.textColor = node.entry.isSafe ? .labelColor : .tertiaryLabelColor
        cell.toolTip = node.entry.isSafe ? nil : L10n.t("archive.unsafe.tooltip")
        cell.imageView?.image = column == Column.name ? icon(for: node) : nil
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        previewButton.isEnabled = selectedNodes.contains { $0.entry.kind == .file && $0.entry.isSafe }
        guard controlsPreviewPanel else { return }
        // Arrow keys page through the archive with the panel open. A file still coming out gives way to the newer selection.
        begin(L10n.t("archive.status.preparing")) { [weak self] in
            try await self?.loadPreview()
            QLPreviewPanel.shared()?.reloadData()
        }
    }
}

extension ArchiveBrowserWindowController: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewItems.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard previewItems.indices.contains(index) else { return nil }
        return previewItems[index] as NSURL
    }

    /// Up and down go to the list, to move through the archive, as in the file views
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, event.keyCode == 125 || event.keyCode == 126 else { return false }
        outline.keyDown(with: event)
        return true
    }
}

/// Text cell, with an icon in the name column
private final class ArchiveCell: NSTableCellView {
    init(identifier: NSUserInterfaceItemIdentifier, showsIcon: Bool) {
        super.init(frame: .zero)
        self.identifier = identifier
        let text = NSTextField(labelWithString: "")
        text.font = .systemFont(ofSize: Formatters.listFontSize)
        text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        textField = text
        var constraints = [
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        ]
        if showsIcon {
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            addSubview(icon)
            imageView = icon
            constraints += [
                icon.leadingAnchor.constraint(equalTo: leadingAnchor),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            ]
        } else {
            constraints.append(text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4))
        }
        NSLayoutConstraint.activate(constraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

final class ArchiveOutlineView: NSOutlineView {
    var onSpace: (() -> Void)?

    /// Space would otherwise go to type-select, when the Quick Look shortcut is bound to something else
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " ",
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            onSpace?()
        } else {
            super.keyDown(with: event)
        }
    }
}

extension MainWindowController {
    /// The one selected item, when it is an archive that can be browsed
    var selectedArchive: URL? {
        let selection = grid.activePane.toolSelection
        guard selection.count == 1, ArchiveEngineNode.isBrowsable(selection[0].url) else { return nil }
        return selection[0].url
    }

    @objc func showArchiveBrowser(_ sender: Any?) {
        guard let archive = selectedArchive else { NSSound.beep(); return }
        ArchiveBrowserWindowController.show(archive: archive, coordinator: coordinator)
    }
}
