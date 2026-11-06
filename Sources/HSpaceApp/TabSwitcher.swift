import AppKit
import TabNavigation

/// What the switcher needs from its window
@MainActor
protocol TabSwitcherHost: AnyObject {
    var switcherWindow: NSWindow? { get }
    /// Workspaces by last use, the active one first
    func switcherEntries() -> [TabSwitcherEntry]
    func switcherCommit(_ workspace: Int)
}

struct TabSwitcherEntry: Equatable {
    let workspace: Int
    let title: String
    let path: String
}

/// Recent tab switcher (L30). Started from a held shortcut it behaves like the system's app switcher: Tab steps, releasing the
/// modifiers switches. Started from the menu it stays until Return, Esc or a click. Its event monitor exists only while it runs.
@MainActor
final class TabSwitcherController {
    /// A quick press and release should not flash the panel
    static let showDelay: Duration = .milliseconds(120)
    private static let width: CGFloat = 400

    private weak var host: (any TabSwitcherHost)?
    private var session: TabSwitcherSession?
    private var entries: [TabSwitcherEntry] = []
    private var heldModifiers: NSEvent.ModifierFlags = []
    private var monitor: Any?
    private var showTask: Task<Void, Never>?
    private var resignObserver: (any NSObjectProtocol)?
    private let list = QuickListView()
    private lazy var panel: QuickPanelSurface = {
        list.onActivate = { [weak self] row in self?.pick(row: row) }
        return QuickPanelSurface(width: Self.width, content: list)
    }()

    /// Current modifiers, replaceable by tests
    var currentModifiers: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }

    init(host: any TabSwitcherHost) {
        self.host = host
    }

    var isActive: Bool { session != nil }
    var isPanelVisible: Bool { session != nil && panel.isVisible }
    var selectedEntry: TabSwitcherEntry? {
        guard let session else { return nil }
        return entries[session.position]
    }
    var shownRows: [QuickRow] { list.rows }

    /// `heldModifiers` empty means nothing has to stay down
    func start(backward: Bool, heldModifiers: NSEvent.ModifierFlags) {
        guard !isActive, let host else { return }
        let entries = host.switcherEntries()
        guard let session = TabSwitcherSession(tabs: entries.map(\.workspace), backward: backward) else {
            NSSound.beep()
            return
        }
        self.entries = entries
        self.session = session
        self.heldModifiers = heldModifiers
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: host.switcherWindow, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
        // The shortcut may be gone already, and then no flagsChanged is coming
        if !heldModifiers.isEmpty, !currentModifiers().isSuperset(of: heldModifiers) {
            commit()
            return
        }
        guard !heldModifiers.isEmpty else { present(); return }
        showTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.showDelay)
            } catch {
                return   // finished before the delay ran out
            }
            self?.present()
        }
    }

    /// Takes an event while running; true means it is used up
    func handle(_ event: NSEvent) -> Bool {
        guard isActive else { return false }
        switch event.type {
        case .flagsChanged:
            if !heldModifiers.isEmpty, !event.modifierFlags.isSuperset(of: heldModifiers) { commit() }
            return false
        case .leftMouseDown:
            if event.window !== panel { cancel() }
            return false
        case .keyDown:
            switch event.keyCode {
            case 48: step(backward: event.modifierFlags.contains(.shift))   // Tab
            case 125: step(backward: false)                                 // Down
            case 126: step(backward: true)                                  // Up
            case 36, 76: commit()                                           // Return, Enter
            case 53: cancel()                                               // Esc
            default: NSSound.beep()
            }
            return true
        default:
            return false
        }
    }

    func step(backward: Bool) {
        session?.step(backward: backward)
        syncSelection()
    }

    func commit() {
        guard let picked = session?.selected else { return }
        finish()
        host?.switcherCommit(picked)
    }

    func cancel() {
        guard isActive else { return }
        finish()
    }

    private func pick(row: Int) {
        session?.select(position: row)
        commit()
    }

    private func present() {
        guard let session else { return }
        list.show(entries.map { entry in
            QuickRow(id: String(entry.workspace), title: entry.title, subtitle: entry.path, symbol: "folder")
        }, selected: session.position)
        panel.present(over: host?.switcherWindow, height: QuickListView.height(for: entries.count), makeKey: false)
        announceSelection()
    }

    private func syncSelection() {
        guard let session, panel.isVisible else { return }
        list.select(session.position)
        announceSelection()
    }

    /// The panel never takes focus, so VoiceOver has to be told
    private func announceSelection() {
        guard let entry = selectedEntry else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: "\(entry.title), \(entry.path)", .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    private func finish() {
        session = nil
        entries = []
        showTask?.cancel()
        showTask = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        panel.dismiss()
    }
}

extension MainWindowController: TabSwitcherHost {
    var switcherWindow: NSWindow? { window }

    func switcherEntries() -> [TabSwitcherEntry] {
        _ = workspaceSnapshot()   // the active workspace's title follows the live pane
        return workspaces.recentOrder.map { index in
            let state = workspaces.states[index]
            let path = WorkspaceManager.path(of: state) ?? ""
            return TabSwitcherEntry(workspace: index, title: WorkspaceManager.title(of: state),
                                    path: (path as NSString).abbreviatingWithTildeInPath)
        }
    }

    func switcherCommit(_ workspace: Int) { switchWorkspace(to: workspace) }
}
