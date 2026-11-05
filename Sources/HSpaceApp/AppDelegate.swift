import FileMetadata
import AppKit
import BatchRename
import HSpaceKernel
import HSpaceContracts
import Transfer
import LocalOps
import ArchiveEngine
import SessionStore
import Frecency
import TrashLedger
import Eraser

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let kernel = OperationKernel()
    /// Conflict arbitration sheet (the kernel's only arbiter): held strongly here, the kernel keeps only a weak-semantics reference
    private let conflictSheet = ConflictSheet()
    private var windowControllers: [MainWindowController] = []
    /// Sole commit owner of session snapshots (M11)
    let sessionStore = SessionStore(directory: AppDelegate.supportDirectory)
    /// Usage learning (M28): app-wide open/enter accounting feeds frecency ranking in focused search. Single instance, injected into each window's coordinator and the search panel.
    let frecencyStore = FrecencyStore(directory: AppDelegate.supportDirectory)
    /// "Put Back" ledger (shared app-wide; every window coordinator is given the same instance).
    /// macOS put-back metadata sits in a private Finder store we cannot read (tested: the only xattr is an empty
    /// com.apple.provenance, mdls shows no origin, Finder's own AppleScript `original item` returns -1728),
    /// so supporting put-back means keeping our own records.
    let trashLedger = TrashLedger(directory: AppDelegate.supportDirectory)
    /// Colour rules and other metadata settings (shared app-wide)
    let metadataStore = MetadataStore(directory: AppDelegate.supportDirectory)
    /// Rename presets and log (L11), shared app-wide
    let renameStore = RenameStore(directory: AppDelegate.supportDirectory)

    /// Application support directory: UITEST uses an isolated temp directory so test fixture paths and records never pollute the user's real session or search ranking
    /// (test sandbox hard rule, same as the I-46 windowFrame isolation; since I-47 sessionStore goes through this too, because navigation persists the session immediately).
    /// The product uses Application Support/HSpace.
    static var supportDirectory: URL {
        let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HSpace")
        #if DEBUG
        if ProcessInfo.processInfo.environment["HSPACE_UITEST"] != nil {
            return FileManager.default.temporaryDirectory.appendingPathComponent("hspace-uitest-support")
        }
        #endif
        return real
    }
    /// State changes are not persisted until restore finishes (stops startup from overwriting the last session with a half-built one)
    private var sessionReady = false
    /// External open requests that arrive before session restore finishes (I-60).
    /// restoreSessionOrDefault is async (it awaits reading session.json), while application(_:open:)
    /// arrives early and synchronously from LaunchServices: when "Reveal in Finder" launches a stopped HSpace, the request lands with zero windows,
    /// activeMainWindowController() returns nil, and it drops into the new-window branch; session restore then opens its own window,
    /// so the user gets an extra window despite having chosen new tab. Queue here and route normally once restore is done.
    private var pendingExternalOpens: [ExternalRequest] = []
    private let externalOpenWorker = ExternalOpenWorker()

    func applicationDidFinishLaunching(_ notification: Notification) {
        ExternalOpenHistory.purgeStoredPath(from: .standard)
        NSApp.mainMenu = MainMenu.build()
        Theme.applyAppearance()   // Appearance: apply light/dark mode at launch (system/light/dark)
        // M28: usage-based ranking; the search panel shares the same frecencyStore (app-wide accounting lives in each window coordinator)
        SearchPanelController.shared.frecencyStore = frecencyStore
        // I-25 reverse entry: Finder context menu "Services > Open with HSpace" (the proper route now that macOS 27 locks the default handler)
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        // M24: global show/hide hotkey (Carbon, no AX needed; the preference is externalized and recordable in Settings > General)
        GlobalHotkey.apply()
        // Composition root (BG-2): declaratively inject the What: pod nodes + conflict arbiter + progress subscription
        Task { @MainActor in
            await kernel.register(TransferNode(), for: [.copy, .move, .duplicate])
            await kernel.register(LocalOpsNode(), for: [.rename, .newFolder, .newFile, .trash])
            let archiveNode = ArchiveEngineNode(compression: {
                ArchiveCompression(rawValue: Preferences.archiveCompressionID) ?? .normal
            })
            await kernel.register(archiveNode, for: [.compress, .extract])
            // Permanent delete gets its own node: an irreversible operation does not share a mature node with the other local operations
            await kernel.register(EraserNode(), for: [.delete])
            await kernel.setArbiter(conflictSheet)
            ProgressWindowController.shared.start(kernel: kernel)
            #if DEBUG
            // Performance self-check entry (for north star acceptance, not a product path): HSPACE_PERF_DIRS=a:b:c:d navigates each quad pane to one directory
            if let spec = ProcessInfo.processInfo.environment["HSPACE_PERF_DIRS"], !spec.isEmpty {
                let dirs = spec.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
                let wc = openWindow(at: dirs[0])
                wc.grid.apply(layout: .quad)
                for (i, dir) in dirs.dropFirst().enumerated() where i + 1 < wc.grid.visiblePanes.count {
                    wc.grid.visiblePanes[i + 1].navigate(to: dir)
                }
            } else {
                await restoreSessionOrDefault()
            }
            #else
            await restoreSessionOrDefault()
            #endif
            sessionReady = true
            flushPendingExternalOpens()   // I-60: deliver the external opens queued during restore (windows exist now)
            NSApp.activate()
            await reportStoreProblems()
            #if DEBUG
            if UISelfTest.isEnabled {
                UISelfTest.run(delegate: self)
            } else if ProcessInfo.processInfo.environment["HSPACE_CONFLICT_PREVIEW"] != nil {
                // Live conflict sheet preview (not a product path, only for human review screenshots): builds fixture conflicts and shows the real sheet
                presentConflictPreview()
            } else if ProcessInfo.processInfo.environment["HSPACE_GROUPING_PREVIEW"] != nil {
                // Live icon view grouping preview (not a product path, only for human review screenshots): builds cross-month fixtures + icon view + grouping
                presentGroupingPreview()
            } else if ProcessInfo.processInfo.environment["HSPACE_PERF_DIRS"] == nil {
                // Permissions prompt: not granted and "Don't ask again" unticked -> show one sheet once the main window is ready (self-test/perf runs are left alone)
                promptFullDiskAccessIfNeeded()
            }
            #else
            promptFullDiskAccessIfNeeded()
            #endif
        }
    }

    #if DEBUG
    /// Live conflict sheet preview (HSPACE_CONFLICT_PREVIEW): builds 3 conflicts in private fixtures and shows the real sheet for screenshots.
    /// Sandbox hard rule: only touch our own fixtures under temporaryDirectory, never the user's real files.
    private func presentConflictPreview() {
        guard let win = NSApp.windows.first(where: { $0.windowController is MainWindowController }) else { return }
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("hspace-conflict-preview")
        let srcDir = base.appendingPathComponent("src")
        let dstDir = base.appendingPathComponent("dst")
        try? fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
        let names = ["Report.pdf", "Budget.xlsx", "Cover.png"]
        var conflicts: [FileConflict] = []
        for n in names {
            let s = srcDir.appendingPathComponent(n)
            let d = dstDir.appendingPathComponent(n)
            try? Data("src".utf8).write(to: s)
            try? Data("dst".utf8).write(to: d)
            conflicts.append(FileConflict(source: s, existing: d, bothDirectories: false))
        }
        // Add one directory conflict too (enables the Merge button, so the preview shows all three buttons active)
        let sSub = srcDir.appendingPathComponent("Assets")
        let dSub = dstDir.appendingPathComponent("Assets")
        try? fm.createDirectory(at: sSub, withIntermediateDirectories: true)
        try? fm.createDirectory(at: dSub, withIntermediateDirectories: true)
        conflicts.insert(FileConflict(source: sSub, existing: dSub, bothDirectories: true), at: 0)
        win.makeKeyAndOrderFront(nil)
        Task { @MainActor in _ = await conflictSheet.arbitrate(operation: UUID(), conflicts: conflicts) }
    }

    /// Live icon view grouping preview (HSPACE_GROUPING_PREVIEW): cross-month fixtures + icon view + grouping, for human review screenshots.
    /// Sandbox hard rule: only touch our own fixtures under temporaryDirectory.
    private func presentGroupingPreview() {
        guard let wc = NSApp.windows.compactMap({ $0.windowController as? MainWindowController }).first else { return }
        let fm = FileManager.default
        let box = fm.temporaryDirectory.appendingPathComponent("hspace-grouping-preview", isDirectory: true)
        try? fm.createDirectory(at: box, withIntermediateDirectories: true)
        let cal = Calendar.current
        for (mi, (y, m)) in [(2026, 8), (2026, 5), (2025, 12)].enumerated() {
            guard let date = cal.date(from: DateComponents(year: y, month: m, day: 15, hour: 12)) else { continue }
            for k in 0..<3 {
                let f = box.appendingPathComponent("File-\(mi)-\(k).txt")
                try? Data("x".utf8).write(to: f)
                try? fm.setAttributes([.modificationDate: date], ofItemAtPath: f.path)
            }
        }
        DefaultsSandbox.standard.begin()   // Undone at quit, so the preview does not leave grouping on for the user
        Preferences.listGrouping = true
        let pane = wc.grid.activePane
        pane.setViewMode(.icons)
        pane.navigate(to: box)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            pane.activeTab.model.sort = SortSpec(key: .dateModified, ascending: false)
            pane.activeTab.model.reload()
            wc.window?.makeKeyAndOrderFront(nil)
        }
    }
    #endif

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Dock click or reactivation with no visible window -> open a new window (I-21: there must be a way back after ⌘W closes the last window)
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openWindow(at: FileManager.default.homeDirectoryForCurrentUser)
        }
        return true
    }

    /// Layered ⌘W close (I-21 user semantics): the target is the key window, or with no key window the topmost visible one in z-order
    /// (the "window on top of the app"). Floating panels (settings/tasks/search etc.) -> close just that;
    /// main window -> close the current workspace tab (the last one closes the window, which Dock can reopen)
    @objc func closeTopmost(_ sender: Any?) {
        guard let target = NSApp.keyWindow ?? NSApp.orderedWindows.first(where: { $0.isVisible }) else { return }
        if let wc = target.windowController as? MainWindowController {
            wc.closeActiveWorkspace(sender)
        } else if target.styleMask.contains(.closable) {
            target.performClose(sender)
        } else {
            target.orderOut(sender)
        }
    }

    /// open-URL routing: directory -> open a window there; file -> parent directory with the file selected (the Finder replacement entry).
    /// hspace:// links (I-25 third-party integration) can only navigate: hspace://open?path=<directory> / hspace://reveal?path=<item>.
    /// Open mode (externalOpenTarget): anything but newWindow, with a window present -> reuse that window and open a new workspace tab there.
    func application(_ application: NSApplication, open urls: [URL]) {
        routeExternalOpens(urls.map { $0.scheme?.lowercased() == "hspace" ? HSpaceURL.parse($0) : .system($0) })
    }

    /// Services menu entry (Finder context menu > Services > Open with HSpace; I-25)
    @objc func openInHSpace(_ pboard: NSPasteboard, userData: String, error: NSErrorPointer) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        routeExternalOpens(urls.map { .system($0) })
        NSApp.activate()
    }

    private func routeExternalOpens(_ requests: [ExternalRequest]) {
        // I-60: routing before the session is restored (zero windows) would only open a surplus window. Queue first.
        guard sessionReady else {
            pendingExternalOpens.append(contentsOf: requests)
            return
        }
        guard !requests.isEmpty else { return }
        // The disk is only read off the main thread: a path on a dead mount or the automounter would otherwise freeze the app
        Task { @MainActor in
            guard let plan = await externalOpenWorker.run({ ExternalOpenPlanner.plan(requests) }) else {
                reportExternalOpenRejection(.timedOut)
                return
            }
            for destination in plan.destinations { openExternalDestination(destination) }
            if let rejection = plan.rejections.first { reportExternalOpenRejection(rejection) }
        }
    }

    private func reportExternalOpenRejection(_ rejection: ExternalOpenRejection) {
        Toast.show(rejection.message, in: activeMainWindowController()?.window)
    }

    private func openExternalDestination(_ destination: ExternalDestination) {
        let directory = destination.directory
        let selecting = destination.selecting
        if Preferences.externalOpenTarget != "newWindow", let wc = activeMainWindowController() {
            // New **workspace tab** in the existing window (default, user request): reuse the active window and point the active pane at the target directory.
            // Before v0.19.26 this used pane.openNewTab: it pushed a tab into the pane, whose tab bar is hidden by default,
            // so every external open piled up somewhere invisible (one user session reached 5 tabs in a pane),
            // impossible to close or return to. The workspace tab strip is always shown and has close buttons, so tabs landing there can be seen and closed.
            //
            // allowEvictingOldest: false: this open comes from **another app**. At the workspace limit we would
            // rather navigate in place than evict the user's oldest workspace because some app hit "Reveal in Finder".
            wc.openWorkspaceTab(at: directory, allowEvictingOldest: false)
            if let selecting { wc.grid.activePane.reveal(selecting) }
            wc.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
        } else if let selecting {
            openWindow(at: directory, selecting: selecting)
        } else {
            openWindow(at: directory)
        }
    }

    /// Active main window (destination for open mode activePane): prefer keyWindow, then mainWindow, then any live window
    private func activeMainWindowController() -> MainWindowController? {
        if let key = NSApp.keyWindow?.windowController as? MainWindowController { return key }
        if let main = NSApp.mainWindow?.windowController as? MainWindowController { return main }
        // Fall back to the **frontmost** visible main window (orderedWindows is front to back), not the "last created" one:
        // after the user closes a new window or switches between windows, that one can sit behind others or be invisible, and the external open lands out of sight.
        if let front = NSApp.orderedWindows.first(where: {
            $0.isVisible && $0.windowController is MainWindowController
        })?.windowController as? MainWindowController {
            return front
        }
        return windowControllers.last { $0.window != nil }
    }

    /// Whether any main window is alive. **Do not use isVisible from NSApp.windows**: unhide is asynchronous,
    /// right after NSApp.unhide(nil) windows still report isVisible false, which reads as "no main window" and opens a surplus empty one
    /// (extra windows when the global hotkey summons HSpace). The window ledger is updated synchronously in windowWillClose and can be trusted.
    var hasLiveMainWindow: Bool { windowControllers.contains { $0.window != nil } }

    /// Look up a window's controller (cross-window drag and drop sends undo/toasts back to the source window)
    func mainWindowController(for window: NSWindow?) -> MainWindowController? {
        guard let window else { return nil }
        return windowControllers.first { $0.window === window }
    }

    /// Frontmost main window (for the global hotkey). Not NSApp.windows.first: a window that was close()d but not yet deallocated
    /// stays in there, and makeKeyAndOrderFront would "revive" it as a zombie the user thinks is long gone.
    var frontmostMainWindow: NSWindow? {
        if let key = NSApp.keyWindow, key.windowController is MainWindowController { return key }
        if let main = NSApp.mainWindow, main.windowController is MainWindowController { return main }
        return windowControllers.last { $0.window != nil }?.window
    }

    @discardableResult
    func openWindow(at directory: URL, selecting: URL? = nil, orderFront: Bool = true) -> MainWindowController {
        let wc = MainWindowController(kernel: kernel, frecencyStore: frecencyStore,
                                      trashLedger: trashLedger,
                                     initialDirectory: directory, select: selecting)
        windowControllers.append(wc)
        wc.window?.delegate = self
        if orderFront { wc.showWindow(nil) }
        return wc
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.showWindow(sender)
    }

    /// Full Disk Access guided prompt: not granted and "Don't ask again" unticked -> show one explanatory sheet on the main window.
    /// Three buttons: grant (opens System Settings) / later (skip now, ask next time) / never ask (sets a Preferences flag).
    /// The stores the app owns. Each window reports its own bookmark and stash stores.
    private func reportStoreProblems() async {
        ProblemAlert.show(await sessionStore.takeProblem())
        ProblemAlert.show(await frecencyStore.takeProblem())
        ProblemAlert.show(await trashLedger.takeProblem())
        await MetadataSettings.load(from: metadataStore)
        ProblemAlert.show(await metadataStore.takeProblem())
    }

    private func promptFullDiskAccessIfNeeded() {
        // A store problem goes first; this prompt comes back at the next launch
        guard !Preferences.fdaPromptDismissed, !FinderIntegration.hasFullDiskAccess(),
              !ProblemAlert.isBusy,
              let window = windowControllers.first(where: { $0.window != nil })?.window else { return }
        let alert = NSAlert()
        alert.messageText = L10n.t("fda.prompt.title")
        alert.informativeText = L10n.t("fda.prompt.body")
        alert.addButton(withTitle: L10n.t("fda.prompt.grant"))
        alert.addButton(withTitle: L10n.t("fda.prompt.later"))
        alert.addButton(withTitle: L10n.t("fda.prompt.never"))
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                switch response {
                case .alertFirstButtonReturn: FinderIntegration.openFullDiskAccessSettings()
                case .alertThirdButtonReturn: Preferences.fdaPromptDismissed = true
                default: break  // Later
                }
            }
        }
    }

    @objc func newWindow(_ sender: Any?) {
        openWindow(at: FileManager.default.homeDirectoryForCurrentUser)
    }

    // MARK: Session restore and save (M11: reopening returns you to where you were)

    private func restoreSessionOrDefault() async {
        // UITEST isolation: self-test assertions rely on a deterministic initial state (single workspace, default layout), not the real user session;
        // frame persistence scenarios (SETFRAME/EXPECTFRAME) use the separate windowFrame key and are unaffected
        #if DEBUG
        if ProcessInfo.processInfo.environment["HSPACE_UITEST"] != nil {
            openWindow(at: FileManager.default.homeDirectoryForCurrentUser)
            return
        }
        #endif
        guard let snapshot = await sessionStore.load(), !snapshot.windows.isEmpty else {
            openWindow(at: FileManager.default.homeDirectoryForCurrentUser)
            return
        }
        // Each saved "window" = one set of workspaces (M17): each becomes its own OS window, and its workspace array restores itself
        var first: MainWindowController?
        for ws in snapshot.windows {
            let firstPane = ws.workspaces.first(where: { !$0.panes.isEmpty })
            let dir = URL(fileURLWithPath: firstPane?.panes.first?.tab.path ?? NSHomeDirectory())
            let wc = openWindow(at: dir, orderFront: first == nil)
            wc.restoreWorkspaces(ws)
            if first == nil { first = wc }
        }
        first?.window?.makeKeyAndOrderFront(nil)
    }

    #if DEBUG
    /// UISelfTest (I-60): number of queued external opens / whether the session is ready
    var uiTestPendingExternalOpenCount: Int { pendingExternalOpens.count }
    var uiTestSessionReady: Bool { sessionReady }

    /// UISelfTest (I-60): deliver an external open in the "session not ready" state (reproduces the cold-start moment)
    func uiTestDeliverExternalOpenWhileNotReady(_ url: URL) {
        let saved = sessionReady
        sessionReady = false
        application(NSApp, open: [url])
        sessionReady = saved
    }

    /// UISelfTest (I-60): flush the queue by hand (simulates session restore finishing)
    func uiTestFlushPendingExternalOpens() { flushPendingExternalOpens() }
    #endif

    /// I-60: deliver external opens queued during session restore (windows exist now, so the normal "new workspace tab in existing window" branch applies)
    private func flushPendingExternalOpens() {
        guard !pendingExternalOpens.isEmpty else { return }
        let queued = pendingExternalOpens
        pendingExternalOpens = []
        routeExternalOpens(queued)
    }

    /// Request to persist state (called on location/layout/workspace changes; SessionStore debounces and merges over 1s internally)
    func noteStateChanged() {
        guard sessionReady else { return }
        let snapshot = SessionSnapshot(windows: windowControllers.compactMap { wc in
            wc.window != nil ? wc.workspaceSnapshot() : nil
        })
        guard !snapshot.windows.isEmpty else { return }
        Task { await sessionStore.save(snapshot) }
    }

    /// Force persistence before quitting (synchronous wait of at most 1s; a snapshot still in debounce is not lost)
    func applicationWillTerminate(_ notification: Notification) {
        let snapshot = SessionSnapshot(windows: windowControllers.compactMap { wc in
            wc.window != nil ? wc.workspaceSnapshot() : nil
        })
        let store = sessionStore
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            if !snapshot.windows.isEmpty { await store.save(snapshot) }
            await store.flush()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1)
        #if DEBUG
        DefaultsSandbox.standard.end()
        #endif
        // Force preferences to disk so the last writes (window size, sidebar width, column visibility, etc.)
        // are persisted before the process exits (a fallback for cfprefsd not having flushed asynchronously)
        UserDefaults.standard.synchronize()
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if let wc = windowControllers.first(where: { $0.window === window }) {
            wc.teardown()
        }
        windowControllers.removeAll { $0.window === window }
        noteStateChanged()
    }

    /// ⌘Z routes to this window's file operation undo stack (undoing a trash, etc.)
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        windowControllers.first(where: { $0.window === window })?.coordinator.undoManager
    }
}
