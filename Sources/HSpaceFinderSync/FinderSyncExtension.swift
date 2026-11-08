import AppKit
import ExtensionBridge
import FinderSync
import Synchronization

private func text(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// Finder Sync extension (L60): badges the items on HSpace's stash shelf and adds "Open in HSpace" and
/// "Add to HSpace Stash" to Finder. It reads what the app publishes and never writes anything itself.
@objc(HSpaceFinderSync)
final class HSpaceFinderSync: FIFinderSync {
    private let bridgeDirectory = BridgeLocation.directory(inSupport: BridgeLocation.appSupportOutsideSandbox())
    /// Finder calls in from several threads
    private let index = Mutex(BadgeIndex(paths: []))

    override init() {
        super.init()
        let controller = FIFinderSyncController.default()
        // Every folder, so the menu items are there wherever the user is. Each badge lookup is one set lookup.
        controller.directoryURLs = [URL(fileURLWithPath: "/")]
        let label = text("finderSync.badge.stashed")
        if let image = NSImage(systemSymbolName: "tray.full.fill", accessibilityDescription: label) {
            controller.setBadgeImage(image, label: label, forBadgeIdentifier: BadgeIndex.stashedBadge)
        }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(bridgeChanged(_:)), name: BridgeLocation.changedNotification, object: nil)
        reloadBadges()
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // MARK: Badges

    override func requestBadgeIdentifier(for url: URL) {
        let badge = index.withLock { $0.badge(forPath: url.path) }
        if let badge { FIFinderSyncController.default().setBadgeIdentifier(badge, for: url) }
    }

    @objc private func bridgeChanged(_ note: Notification) {
        reloadBadges()
    }

    /// Re-reads the snapshot and tells Finder about the items whose badge changed. An unreadable snapshot
    /// clears every badge rather than leaving stale ones.
    private func reloadBadges() {
        let paths: [String]
        switch BridgeReader.read(from: bridgeDirectory) {
        case .success(let snapshot):
            paths = snapshot?.stashedPaths ?? []
        case .failure(let error):
            NSLog("HSpace Finder extension: %@", error.localizedDescription)
            paths = []
        }
        let new = BadgeIndex(paths: paths)
        let changed = index.withLock { current in
            defer { current = new }
            return BadgeIndex.changes(from: current, to: new)
        }
        let controller = FIFinderSyncController.default()
        for path in changed {
            controller.setBadgeIdentifier(new.badge(forPath: path) ?? "", for: URL(fileURLWithPath: path))
        }
    }

    // MARK: Menus and toolbar

    override var toolbarItemName: String { "HSpace" }
    override var toolbarItemToolTip: String { text("finderSync.toolbar.tooltip") }
    override var toolbarItemImage: NSImage {
        NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "HSpace") ?? NSImage()
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "")
        let open = NSMenuItem(title: text("finderSync.menu.open"), action: #selector(openInHSpace(_:)), keyEquivalent: "")
        open.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: nil)
        menu.addItem(open)
        if menuKind == .contextualMenuForItems {
            let stash = NSMenuItem(title: text("finderSync.menu.stash"), action: #selector(addToStash(_:)), keyEquivalent: "")
            stash.image = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: nil)
            menu.addItem(stash)
        }
        return menu
    }

    /// Selected items, or the folder Finder shows when nothing is selected
    private func targets() -> [URL] {
        let controller = FIFinderSyncController.default()
        if let selected = controller.selectedItemURLs(), !selected.isEmpty { return selected }
        return controller.targetedURL().map { [$0] } ?? []
    }

    @objc private func openInHSpace(_ sender: AnyObject?) {
        let urls = targets()
        guard !urls.isEmpty else { return }
        // HSpace opens a folder, and shows a file selected in its folder
        NSWorkspace.shared.open(urls, withApplicationAt: Self.containingApp, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func addToStash(_ sender: AnyObject?) {
        let paths = targets().map(\.path)
        guard !paths.isEmpty else { return }
        switch BridgeReader.read(from: bridgeDirectory) {
        case .success(let snapshot?):
            guard let link = StashLink.make(paths: Array(paths.prefix(StashLink.maxItems)), token: snapshot.token) else { return }
            NSWorkspace.shared.open(link)
        case .success(nil):
            // HSpace has not run yet: opening it publishes the snapshot, and the next try works
            NSWorkspace.shared.openApplication(at: Self.containingApp, configuration: NSWorkspace.OpenConfiguration())
        case .failure(let error):
            NSLog("HSpace Finder extension: %@", error.localizedDescription)
            NSWorkspace.shared.openApplication(at: Self.containingApp, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// HSpace.app, three levels up from Contents/PlugIns/HSpaceFinderSync.appex
    private static var containingApp: URL {
        Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}
