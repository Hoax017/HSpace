import AppKit
import ExtensionBridge
import UniformTypeIdentifiers

private func text(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// Share extension (L61): "Share > HSpace Stash" from Finder or any app that shares files. It shows what will be
/// stashed and, on Add, hands the paths to HSpace through a stash link. It writes nothing itself.
@objc(HSpaceShareViewController)
final class HSpaceShareViewController: NSViewController {
    private let message = NSTextField(wrappingLabelWithString: "")
    private let addButton = NSButton()
    private var paths: [String] = []

    override func loadView() {
        let icon = NSImageView(image: NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 20, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        let title = NSTextField(labelWithString: text("share.title"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let header = NSStackView(views: [icon, title])
        header.spacing = 8

        message.font = .systemFont(ofSize: 12)
        message.textColor = .secondaryLabelColor
        message.stringValue = text("share.reading")

        let cancel = NSButton(title: text("share.cancel"), target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        addButton.title = text("share.add")
        addButton.bezelStyle = .push
        addButton.target = self
        addButton.action = #selector(add(_:))
        addButton.keyEquivalent = "\r"
        addButton.isEnabled = false
        let buttons = NSStackView(views: [NSView(), cancel, addButton])
        buttons.spacing = 8

        let stack = NSStackView(views: [header, message, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.widthAnchor.constraint(equalToConstant: 360),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            message.widthAnchor.constraint(equalTo: buttons.widthAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        loadURLs(from: providers) { [weak self] urls in self?.show(urls) }
    }

    /// Every provider answers on its own queue; the result comes back on the main thread, in the order shared
    private func loadURLs(from providers: [NSItemProvider], then done: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        let results = ResultSlots(count: providers.count)
        for (i, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                results.set(i, url)
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated { done(results.values) }
        }
    }

    private func show(_ urls: [URL]) {
        switch ShareInput.paths(from: urls) {
        case .success(let found):
            paths = found
            message.stringValue = found.count == 1
                ? String(format: text("share.one"), (found[0] as NSString).lastPathComponent)
                : String(format: text("share.many"), found.count)
            addButton.isEnabled = true
        case .failure(.noFiles):
            message.stringValue = text("share.noFiles")
        case .failure(.tooManyItems):
            message.stringValue = String(format: text("share.tooMany"), StashLink.maxItems)
        }
    }

    @objc private func add(_ sender: Any?) {
        switch BridgeReader.read(from: BridgeLocation.directory(inSupport: BridgeLocation.appSupportOutsideSandbox())) {
        case .success(let snapshot?):
            guard let link = StashLink.make(paths: paths, token: snapshot.token) else { return }
            NSWorkspace.shared.open(link)
            extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        case .success(nil):
            // HSpace has not run yet, so it has not published the secret a link needs
            message.stringValue = text("share.openFirst")
            addButton.isEnabled = false
        case .failure(let error):
            message.stringValue = error.localizedDescription
            addButton.isEnabled = false
        }
    }

    @objc private func cancel(_ sender: Any?) {
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }
}

/// Collects answers that arrive on any thread
private final class ResultSlots: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [URL?]

    init(count: Int) {
        slots = Array(repeating: nil, count: count)
    }

    func set(_ index: Int, _ url: URL?) {
        lock.withLock { slots[index] = url }
    }

    var values: [URL] {
        lock.withLock { slots.compactMap { $0 } }
    }
}
