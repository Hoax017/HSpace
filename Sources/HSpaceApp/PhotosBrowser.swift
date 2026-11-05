import AppKit
import PhotoLibrary

/// What the Photos window shows, apart from AppKit, so that denial and failure can be tested.
@MainActor
final class PhotosBrowserModel {
    enum State: Equatable {
        case checking
        /// macOS has not asked yet. Nothing touches the library until the owner presses the button.
        case needsPermission
        case denied
        case restricted
        case ready
        case failed(String)
    }

    let library: any PhotoLibraryProviding
    private(set) var state = State.checking { didSet { onChange?() } }
    private(set) var collections: [PhotoCollection] = []
    private(set) var current: PhotoCollection?
    private(set) var assets: [PhotoAsset] = []
    private(set) var isLoadingAssets = false
    var onChange: (() -> Void)?
    private var loadTask: Task<Void, Never>?

    init(library: any PhotoLibraryProviding) {
        self.library = library
    }

    func start() async {
        apply(library.access())
        if state == .ready { await loadCollections() }
    }

    func requestAccess() async {
        apply(await library.requestAccess())
        if state == .ready { await loadCollections() }
    }

    private func apply(_ access: PhotoAccess) {
        switch access {
        case .notDetermined: state = .needsPermission
        case .granted, .limited: state = .ready
        case .denied: state = .denied
        case .restricted: state = .restricted
        }
    }

    private func loadCollections() async {
        do {
            collections = try await library.collections()
            onChange?()
            if let first = collections.first { await show(first) }
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// A slower earlier album can never replace a newer choice
    func show(_ collection: PhotoCollection) async {
        loadTask?.cancel()
        current = collection
        assets = []
        isLoadingAssets = true
        onChange?()
        let task = Task { [library] in
            do {
                let found = try await library.assets(in: collection)
                guard !Task.isCancelled else { return }
                self.assets = found
                self.isLoadingAssets = false
                self.onChange?()
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self.isLoadingAssets = false
                self.state = .failed(error.localizedDescription)
            }
        }
        loadTask = task
        await task.value
    }

    func stop() {
        loadTask?.cancel()
    }

    var statusText: String {
        isLoadingAssets ? L10n.t("photos.loading") : L10n.f("inspector.itemCount", assets.count)
    }

    /// Where the panel's message comes from: nil when the content shows
    var message: String? {
        switch state {
        case .checking, .ready: nil
        case .needsPermission: L10n.t("photos.needsPermission")
        case .denied: L10n.t("photos.denied")
        case .restricted: L10n.t("photos.restricted")
        case .failed(let reason): reason
        }
    }
}

/// One thumbnail
@MainActor
final class PhotoGridItem: NSCollectionViewItem {
    static let reuseID = NSUserInterfaceItemIdentifier("photoGridItem")
    private let image = NSImageView()
    private let badge = NSImageView()
    private var loading: Task<Void, Never>?

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 4
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false
        badge.image = NSImage(systemSymbolName: "video.fill", accessibilityDescription: nil)
        badge.contentTintColor = .white
        badge.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(image)
        root.addSubview(badge)
        NSLayoutConstraint.activate([
            image.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
            image.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -4),
            image.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            image.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            badge.bottomAnchor.constraint(equalTo: image.bottomAnchor, constant: -4),
            badge.leadingAnchor.constraint(equalTo: image.leadingAnchor, constant: 4),
        ])
        view = root
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.backgroundColor = isSelected ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.30).cgColor : nil
        }
    }

    func show(_ asset: PhotoAsset, from library: any PhotoLibraryProviding) {
        image.image = nil
        badge.isHidden = !asset.isVideo
        let kind = L10n.t(asset.isVideo ? "photos.kind.video" : "photos.kind.photo")
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        view.setAccessibilityLabel(asset.created.map { "\(kind), \(Formatters.relativeDate($0))" } ?? kind)
        loading?.cancel()
        loading = Task { [weak self] in
            let picture = await library.thumbnail(of: asset, side: 240)
            guard let self, !Task.isCancelled, let picture else { return }
            self.image.image = NSImage(cgImage: picture, size: .zero)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loading?.cancel()
        image.image = nil
    }
}

/// The Photos library in a window of its own: albums on the left, thumbnails on the right, and a way to copy originals to the active pane.
/// The pane's content is a real folder, and the library is not one, so browsing it inside a pane has to wait for the virtual file system (Phase 2).
@MainActor
final class PhotosBrowserWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate,
                                           NSCollectionViewDataSource, NSCollectionViewDelegate {
    private static var live: PhotosBrowserWindowController?

    /// Opens or brings forward the window. `destination` is asked at the moment of export, so it follows the active pane.
    static func present(library: any PhotoLibraryProviding, destination: @escaping @MainActor () -> URL?) {
        if let open = live {
            open.destination = destination
            open.showWindow(nil)
            return
        }
        let controller = PhotosBrowserWindowController(library: library, destination: destination)
        live = controller
        controller.showWindow(nil)
        Task { await controller.model.start() }
    }

    let model: PhotosBrowserModel
    private var destination: @MainActor () -> URL?
    private let albums = NSTableView()
    private let flow = NSCollectionViewFlowLayout()
    private let grid = NSCollectionView()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let actionButton = NSButton()
    private let status = ToolUI.label()
    private let bar = ToolUI.progressBar()
    private lazy var exportButton = ToolUI.button(L10n.t("photos.copy"), target: self, action: #selector(exportTapped))
    private lazy var cancelButton = ToolUI.button(L10n.t("common.cancel"), target: self, action: #selector(cancelTapped))
    private var exportTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?

    private init(library: any PhotoLibraryProviding, destination: @escaping @MainActor () -> URL?) {
        model = PhotosBrowserModel(library: library)
        self.destination = destination
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.t("photos.title")
        window.minSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        build(in: window)
        model.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    private func build(in window: NSWindow) {
        let column = NSTableColumn(identifier: .init("album"))
        column.title = L10n.t("photos.albums")
        albums.addTableColumn(column)
        albums.headerView = nil
        albums.style = .sourceList
        albums.dataSource = self
        albums.delegate = self
        albums.setAccessibilityLabel(L10n.t("photos.albums"))
        let albumScroll = NSScrollView()
        albumScroll.documentView = albums
        albumScroll.hasVerticalScroller = true
        albumScroll.drawsBackground = false

        flow.itemSize = NSSize(width: 128, height: 128)
        flow.minimumInteritemSpacing = 4
        flow.minimumLineSpacing = 4
        flow.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        grid.collectionViewLayout = flow
        grid.isSelectable = true
        grid.allowsMultipleSelection = true
        grid.backgroundColors = [.clear]
        grid.dataSource = self
        grid.delegate = self
        grid.register(PhotoGridItem.self, forItemWithIdentifier: PhotoGridItem.reuseID)
        grid.setAccessibilityLabel(L10n.t("photos.title"))
        let gridScroll = NSScrollView()
        gridScroll.documentView = grid
        gridScroll.hasVerticalScroller = true

        messageLabel.alignment = .center
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.textColor = .secondaryLabelColor
        actionButton.bezelStyle = .rounded
        actionButton.target = self
        actionButton.action = #selector(actionTapped)
        let notice = NSStackView(views: [messageLabel, actionButton])
        notice.orientation = .vertical
        notice.spacing = 12

        let rule = NSBox()
        rule.boxType = .separator
        let foot = NSBox()
        foot.boxType = .separator
        cancelButton.isHidden = true
        let footer = ToolUI.buttonRow(leading: status, [cancelButton, exportButton])
        bar.widthAnchor.constraint(equalToConstant: 160).isActive = true
        footer.insertArrangedSubview(bar, at: 1)

        let root = NSView()
        for sub in [albumScroll, rule, gridScroll, notice, foot, footer] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            albumScroll.topAnchor.constraint(equalTo: root.topAnchor),
            albumScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            albumScroll.bottomAnchor.constraint(equalTo: foot.topAnchor),
            albumScroll.widthAnchor.constraint(equalToConstant: 200),
            rule.topAnchor.constraint(equalTo: root.topAnchor),
            rule.bottomAnchor.constraint(equalTo: foot.topAnchor),
            rule.leadingAnchor.constraint(equalTo: albumScroll.trailingAnchor),
            gridScroll.topAnchor.constraint(equalTo: root.topAnchor),
            gridScroll.leadingAnchor.constraint(equalTo: rule.trailingAnchor),
            gridScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            gridScroll.bottomAnchor.constraint(equalTo: foot.topAnchor),
            notice.centerXAnchor.constraint(equalTo: gridScroll.centerXAnchor),
            notice.centerYAnchor.constraint(equalTo: gridScroll.centerYAnchor),
            notice.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            foot.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            foot.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.topAnchor.constraint(equalTo: foot.bottomAnchor, constant: 8),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        window.contentView = root
    }

    private func refresh() {
        albums.reloadData()
        if let current = model.current, let row = model.collections.firstIndex(of: current) {
            albums.selectRowIndexes([row], byExtendingSelection: false)
        }
        grid.reloadData()
        grid.enclosingScrollView?.isHidden = model.message != nil
        messageLabel.stringValue = model.message ?? ""
        messageLabel.superview?.isHidden = model.message == nil
        switch model.state {
        case .needsPermission:
            actionButton.title = L10n.t("photos.allow")
            actionButton.isHidden = false
        case .denied:
            actionButton.title = L10n.t("photos.openSettings")
            actionButton.isHidden = false
        default:
            actionButton.isHidden = true
        }
        status.stringValue = model.state == .ready ? model.statusText : ""
        syncExportButton()
    }

    private func syncExportButton() {
        exportButton.isEnabled = !grid.selectionIndexPaths.isEmpty && exportTask == nil
    }

    @objc private func actionTapped() {
        switch model.state {
        case .needsPermission:
            Task { await model.requestAccess() }
        case .denied:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
    }

    @objc private func exportTapped() {
        guard let target = destination(), !TrashLocation.isInsideTrash(target) else {
            ToolUI.showError(L10n.t("photos.noDestination"), in: window)
            return
        }
        let picked = grid.selectionIndexPaths.sorted().compactMap { model.assets[safe: $0.item] }
        guard !picked.isEmpty else { return }
        bar.doubleValue = 0
        bar.isHidden = false
        cancelButton.isHidden = false
        let exporter = PhotoExporter(library: model.library)
        exportTask = Task { [weak self] in
            let report = await exporter.export(picked, to: target) { done, total in
                Task { @MainActor in self?.bar.doubleValue = Double(done) / Double(max(total, 1)) }
            }
            self?.finishExport(report, of: picked.count, to: target)
        }
        syncExportButton()
    }

    private func finishExport(_ report: PhotoExportReport, of total: Int, to target: URL) {
        exportTask = nil
        bar.isHidden = true
        cancelButton.isHidden = true
        syncExportButton()
        status.stringValue = L10n.f("photos.copied", report.exported.count, target.lastPathComponent)
        if let first = report.failures.first {
            ToolUI.showError(L10n.f("photos.copyFailed", report.failures.count, first.message), in: window)
        }
    }

    @objc private func cancelTapped() { exportTask?.cancel() }

    // MARK: Albums

    func numberOfRows(in tableView: NSTableView) -> Int { model.collections.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let collection = model.collections[safe: row]
        return ToolUI.cell(in: tableView, text: collection?.kind == .allPhotos ? L10n.t("photos.all") : collection?.title ?? "")
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let collection = model.collections[safe: albums.selectedRow], collection != model.current else { return }
        loadTask = Task { await model.show(collection) }
    }

    // MARK: Thumbnails

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        model.assets.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: PhotoGridItem.reuseID, for: indexPath)
        if let cell = item as? PhotoGridItem, let asset = model.assets[safe: indexPath.item] {
            cell.show(asset, from: model.library)
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { syncExportButton() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { syncExportButton() }

    // MARK: Closing

    /// Back from System Settings: the owner may just have allowed access
    func windowDidBecomeKey(_ notification: Notification) {
        if model.state == .denied { Task { await model.start() } }
    }

    func windowWillClose(_ notification: Notification) {
        exportTask?.cancel()
        model.stop()
        Self.live = nil
    }
}

extension MainWindowController {
    @objc func showPhotosLibrary(_ sender: Any?) {
        PhotosBrowserWindowController.present(library: SystemPhotoLibrary()) { [weak self] in
            self?.grid.activePane.activeTab.browser.current
        }
    }
}
