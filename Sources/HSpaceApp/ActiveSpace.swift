import AppKit
import DragShake

/// Brings a window to the Space the user is in, rather than taking the user to the window's Space (L35)
@MainActor
enum ActiveSpace {
    /// A full-screen window is its own Space and cannot move
    static func bring(_ window: NSWindow, isOnActiveSpace: Bool? = nil) {
        let onSpace = isOnActiveSpace ?? window.isOnActiveSpace
        guard !onSpace, !window.styleMask.contains(.fullScreen) else {
            window.makeKeyAndOrderFront(nil)
            return
        }
        // The behaviour applies while the window is ordered in, and only that once: left on, the window would follow every Space change
        let behavior = window.collectionBehavior
        window.collectionBehavior = behavior.union(.moveToActiveSpace)
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { window.collectionBehavior = behavior }
    }
}

/// Watches for a shake while files are being dragged, from any app. Mouse monitors need no permission, and run only
/// on drag events: nothing happens at rest. Installed only while the setting is on.
@MainActor
final class DragShakeMonitor {
    var onShake: (() -> Void)?
    private var monitors: [Any] = []
    private var detector = ShakeDetector()
    private let pasteboard: NSPasteboard
    private var changeCountAtPress = 0

    init(pasteboard: NSPasteboard = NSPasteboard(name: .drag)) {
        self.pasteboard = pasteboard
    }

    var isEnabled: Bool { !monitors.isEmpty }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        guard enabled else {
            monitors.forEach(NSEvent.removeMonitor)
            monitors = []
            return
        }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged]
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            let (isPress, time) = (event.type == .leftMouseDown, event.timestamp)
            MainActor.assumeIsolated {
                if isPress { self?.pressed() } else { self?.dragged(x: NSEvent.mouseLocation.x, time: time) }
            }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            if event.type == .leftMouseDown { self?.pressed() } else { self?.dragged(x: NSEvent.mouseLocation.x, time: event.timestamp) }
            return event
        }
        monitors = [global, local].compactMap { $0 }
    }

    func pressed() {
        detector.reset()
        changeCountAtPress = pasteboard.changeCount
    }

    func dragged(x: Double, time: TimeInterval) {
        guard detector.feed(x: x, time: time), holdsFiles else { return }
        onShake?()
    }

    /// Asked only once a shake completes: this is a call to the pasteboard server. A stale pasteboard from an earlier drag does not count.
    private var holdsFiles: Bool {
        pasteboard.changeCount != changeCountAtPress && pasteboard.types?.contains(.fileURL) == true
    }
}

extension AppDelegate {
    /// Window > Bring to Active Space, also in the Dock menu, where it works from any Space
    @objc func bringWindowsToActiveSpace(_ sender: Any?) {
        NSApp.activate()
        guard let front = frontmostMainWindow else {
            openWindow(at: FileManager.default.homeDirectoryForCurrentUser)
            return
        }
        for controller in liveMainWindows where controller.window !== front {
            if let window = controller.window { ActiveSpace.bring(window) }
        }
        ActiveSpace.bring(front)   // last, so it ends up in front
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: L10n.t("menu.bringToActiveSpace"), action: #selector(bringWindowsToActiveSpace(_:)), keyEquivalent: "").target = self
        return menu
    }

    /// A shake during a file drag: HSpace comes to this Space with the stash shelf showing, ready for the drop
    func summonForDrop() {
        NSApp.activate()
        guard let front = frontmostMainWindow else {
            openWindow(at: FileManager.default.homeDirectoryForCurrentUser)
            return
        }
        ActiveSpace.bring(front)
        mainWindowController(for: front)?.setSidebar(collapsed: false)
    }
}
