#if DEBUG
import AppKit
import HSpaceContracts
import SearchEngine
import Frecency

/// UI self-test channel (runs automatically after launch when HSPACE_UITEST=1; not a product path, compiled into debug builds only).
/// Needs no Accessibility or Screen Recording permission: scenarios are driven programmatically, screenshots are self-rendered (cacheDisplay),
/// assertions are written to /tmp/hspace-ui/report.txt, and the process exits with 0/1 based on the result when done.
@MainActor
enum UISelfTest {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["HSPACE_UITEST"] == "1"
    }

    private static let outDir: URL = {
        // Parallel worktree isolation: HSPACE_UITEST_OUT names a private output directory so instances do not fight over /tmp/hspace-ui
        if let custom = ProcessInfo.processInfo.environment["HSPACE_UITEST_OUT"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return URL(fileURLWithPath: "/tmp/hspace-ui")
    }()
    private static var lines: [String] = []
    private static var failed = false

    static func run(delegate: AppDelegate) {
        // Watchdog: if any scenario's await hangs (waiting on an interactive sheet, say), force a FAIL finish after 180 s; never hang forever
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(180))
            record(false, "Watchdog fired: self-test timed out before finishing (see progress.txt for the last point reached)")
            finish()
        }
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            lines = []
            failed = false
            // Wait for the window to be ready
            try? await Task.sleep(for: .milliseconds(600))
            guard let wc = NSApp.windows.compactMap({ $0.windowController as? MainWindowController }).first,
                  let window = wc.window else {
                record(false, "Window was not created")
                return finish()
            }
            // harness preflight: force this app to be the active foreground app so the scenarios that follow, which need real key-window focus (the I-30 field-editor completion
            // popup), can show it, and another foreground app stealing focus cannot hang the popup's nested runloop (hardening for parallel/background launches).
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(200))

            // Scenario 0: frame persistence end to end (the SETFRAME phase sets and exits; the EXPECT phase asserts the restore)
            let env = ProcessInfo.processInfo.environment
            if let spec = env["HSPACE_UITEST_SETFRAME"] {
                let parts = spec.split(separator: ",").compactMap { Double($0) }
                if parts.count == 2 {
                    // All main windows share one windowFrame.uitest key: as long as a second window exists,
                    // one frame change from it before this process exits overwrites the value just written
                    // (measured: one in three runs reproduced "expected 900x520, got 600x400", and 600x400 is exactly the default size of a new window).
                    // Keep only the window under test for this persistence pass to remove the race; this cuts the instrument, not the product's persistence path.
                    for w in NSApp.windows
                    where (w.windowController is MainWindowController) && w !== window { w.close() }
                    window.setFrame(NSRect(x: 120, y: 120, width: parts[0], height: parts[1]),
                                    display: true)
                    // Go through self-managed persistence explicitly (simulates the save path at the end of a user drag)
                    // Use the real chain: post didEndLiveResize → observer persistFrameNow (no direct-call shortcuts,
                    // or a broken observer wiring goes undetected; hardened after the user challenged it on 2026-08-26)
                    NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification,
                                                    object: wc.window)
                    try? await Task.sleep(for: .milliseconds(300))
                    record(true, "SETFRAME \(Int(parts[0]))x\(Int(parts[1])) set, exiting")
                }
                return finish()
            }
            if let spec = env["HSPACE_UITEST_EXPECTFRAME"] {
                let parts = spec.split(separator: ",").compactMap { Double($0) }
                if parts.count == 2 {
                    let ok = abs(window.frame.width - parts[0]) < 2 && abs(window.frame.height - parts[1]) < 2
                    record(ok, "frame persistence restored: expected \(Int(parts[0]))x\(Int(parts[1])) got \(Int(window.frame.width))x\(Int(window.frame.height))")
                }
                // Continue with the regular scenarios
            }

            if env["HSPACE_UITEST_ONLY"] == "trash" {
                wc.grid.apply(layout: .single)
                await runTrashNavigationScenario(wc: wc, window: window)
                await runTrashOperationsScenario(wc: wc, window: window)
                await runEmptyTrashButtonScenario(wc: wc, window: window)
                return finish()
            }

            capture(window, "00-baseline")
            let baseline = window.frame
            // Root-cause lock for window size persistence (user report: "size reverts to default after an update"): disable macOS native window restoration,
            // the self-managed windowFrame key alone is authoritative, so a cross-version update does not compete with a savedState the system invalidated
            record(window.isRestorable == false,
                   "Window size self-restored: isRestorable=false (does not compete with macOS native restoration)")
            // Catch it in the act: log the call stack on any window size change (to find what really "changes window size on view switch")
            var resizeLogs: [String] = []
            let obs = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main) { note in
                let f = (note.object as? NSWindow)?.frame ?? .zero
                var dump: [String] = []
                func walk(_ v: NSView, depth: Int) {
                    for c in v.constraints where c.priority == .required
                        && c.relation == .equal && c.secondItem == nil && c.constant > 0
                        && (c.firstAttribute == .width || c.firstAttribute == .height) {
                        var extra = ""
                        if v is NSSplitView {
                            extra = " frame=\(Int(v.frame.width))x\(Int(v.frame.height)) super=\(type(of: v.superview as Any)) tamic=\(v.translatesAutoresizingMaskIntoConstraints) vertical=\((v as! NSSplitView).isVertical) arranged=\((v as! NSSplitView).arrangedSubviews.map { String(describing: type(of: $0)) })"
                        }
                        dump.append("\(String(repeating: " ", count: depth))\(type(of: v)) \(c.firstAttribute == .width ? "W" : "H")==\(Int(c.constant))\(extra)")
                    }
                    for sub in v.subviews { walk(sub, depth: depth + 1) }
                }
                if let cv = (note.object as? NSWindow)?.contentView { walk(cv, depth: 0) }
                resizeLogs.append("RESIZE → \(Int(f.width))x\(Int(f.height))\nrequired size constraints:\n" + dump.joined(separator: "\n"))
            }
            defer { NotificationCenter.default.removeObserver(obs) }

            await runInitialLayoutScenario(wc: wc, window: window, baseline: baseline)

            await runFileOperationsScenario(wc: wc, window: window)

            // HSPACE_UITEST_ONLY=i37: focused I-37 run (skips I-30/I-32: both depend on the nested event loop of the NSTextView.complete()
            // completion popup, which blocks in a headless environment that is not frontmost or has no key window). For debugging I-37 only.
            let focusI37 = env["HSPACE_UITEST_ONLY"] == "i37"
            if !focusI37 {
                await runPathCompletionScenario(wc: wc, window: window)
                await runPathEditingScenario(wc: wc, window: window)
                await runPathParsingScenario(wc: wc, window: window)
                await runPathEdgeCasesScenario(wc: wc, window: window)
                await runPathFocusScenario(wc: wc, window: window)
                await runSortIndicatorScenario(wc: wc, window: window)
                await runDirectoryCopyPathScenario(wc: wc, window: window)
                await runExternalOpenQueueScenario(wc: wc, window: window, delegate: delegate)
                await runTrashSelectionScenario(wc: wc, window: window)
            }

            await runBreadcrumbFitScenario(wc: wc, window: window)

            // ── Scenario I-62: Trash: deck button always usable, click navigates in-app, drop = move to Trash ────────
            // No Trash fixtures are created while debugging the breadcrumb.
            if !focusI37 {
                await runTrashNavigationScenario(wc: wc, window: window)
                await runTrashOperationsScenario(wc: wc, window: window)
                await runEmptyTrashButtonScenario(wc: wc, window: window)
            }

            await runBreadcrumbHitScenario(wc: wc, window: window)

            if focusI37 { return finish() }   // Focused mode: finish once I-37 is verified

            // ── Scenario I-65: ⌘V pastes as a new file / click on selected item renames / blank bottom area / new-file shortcut ──
            await runPasteAndRenameScenario(wc: wc, window: window)

            // ── Scenario I-66: settings search box (finds items + jumps to the right page) ──────────────────────
            await runSettingsSearchScenario(window: window)

            // ── Scenario I-67: copy/cut must not clear the selection ───────────────────────────────────
            await runSelectionSurvivesClipboardScenario(wc: wc, window: window)

            // ── Scenario I-68: sidebar navigates on the first click + highlight follows the pane ────────────────────────────
            await runSidebarNavigationScenario(wc: wc, window: window)


            // ── Scenario I-70/71/72: ⌘T new workspace inherits / ⌥⌘T tab bar visible / workspace tab bar clickable ────
            await runWorkspaceTabScenario(wc: wc, window: window)
            // ── Scenario M26: list "year/month" grouping + collapse + group filter + selection kept across sorts + toggle ─────────
            // Hard rule: touch only self-created hspace-uitest-m26-* fixtures (assertSandboxed guard); 6 files spread over 3 different year-months.
            await runGroupingScenario(wc: wc, window: window)

            // ── Scenario M29: relative time pure logic (6 bucket keyTitle placement + date column hides the year this year, shows it otherwise) ──────
            runRelativeTimeUnit()

            // ── Scenario I-46: frame persistence key is isolated under UITEST, never polluting the user's real windowFrame ──────────
            record(MainWindowController.frameDefaultsKey == "windowFrame.uitest",
                   "I-46 UITEST frame key isolated (writes windowFrame.uitest, leaves the product windowFrame alone)")
            // The same hard rule extended to sidebar width: isolating the window frame alone is not enough. The column width in the I-37 narrow-window assertion
            // = 511 - sidebarWidth and drifts with the developer's real sidebar width; dragged to the 320 limit it eats the margin and goes red because of the environment
            record(MainWindowController.sidebarWidthKey == "sidebarWidth.uitest",
                   "I-46 UITEST sidebar width key isolated (writes sidebarWidth.uitest, leaves the product sidebarWidth alone)")

            // M28/I-47 test sandbox: under UITEST, frecency accounting and session saves go to an isolated temp directory, never polluting the user's real ranking/session
            record(AppDelegate.supportDirectory.path.contains("hspace-uitest-support"),
                   "M28/I-47 UITEST storage isolation (frecency/session written to a temp directory, real user data untouched)")

            // ── Scenario I-43: collapse-on-click-inside-selection predicate (pure logic, deterministic; the 0.5s→0.16s behaviour was measured with instrumentation on a real machine) ─────
            let i43a = FocusReportingTableView.shouldPreemptCollapse(clickedRow: 2, modifiers: [], clickCount: 1, selectedCount: 5, rowIsSelected: true)
            let i43cmd = FocusReportingTableView.shouldPreemptCollapse(clickedRow: 2, modifiers: [.command], clickCount: 1, selectedCount: 5, rowIsSelected: true)
            let i43dbl = FocusReportingTableView.shouldPreemptCollapse(clickedRow: 2, modifiers: [], clickCount: 2, selectedCount: 5, rowIsSelected: true)
            let i43out = FocusReportingTableView.shouldPreemptCollapse(clickedRow: 9, modifiers: [], clickCount: 1, selectedCount: 5, rowIsSelected: false)
            let i43single = FocusReportingTableView.shouldPreemptCollapse(clickedRow: 2, modifiers: [], clickCount: 1, selectedCount: 1, rowIsSelected: true)
            record(i43a && !i43cmd && !i43dbl && !i43out && !i43single,
                   "I-43 click-inside-selection collapse predicate: plain click on a selected row in a multi-selection = collapse early; modifier/double click/outside selection/single selection = no intervention (\(i43a)/\(i43cmd)/\(i43dbl)/\(i43out)/\(i43single))")

            // ── Scenario M28: smart search ranking (frecency + match blend) takes over sorting vs falling back to arrival order when toggled off ──────────
            runSmartSortScenario()

            // ── Scenario I-47: navigation persists immediately (the session remembers the last directory; an unclean exit does not return to home) ──────────────────
            await runSessionSaveScenario(delegate: delegate)

            // ── Scenario I-44: third-party "open file location" → openWindow(selecting:) really locates and selects (list + icons) ──
            await runRevealSelectScenario(delegate: delegate)

            // Scenario 5: spotlight search panel opens and closes without crashing + I-19 hidden-files toggle visibility check (captures the panel itself)
            Self.extraDump = resizeLogs
            wc.showSearchGlobal(nil)
            try? await Task.sleep(for: .milliseconds(400))
            record(true, "Search panel opened without crashing")
            capture(window, "05-search")
            // I-19: scan all windows for the panel (keyWindow is unavailable under UITEST), verify the hidden toggle exists and is visible
            let panelWin = NSApp.windows.first { w in
                w.isVisible && !(w.windowController is MainWindowController) &&
                viewTree(w.contentView).contains { ($0 as? NSButton)?.title == L10n.t("search.includeHidden") }
            }
            if let panelWin {
                capture(panelWin, "05b-search-panel")
                let hiddenBtn = viewTree(panelWin.contentView).compactMap { $0 as? NSButton }
                    .first { $0.title == L10n.t("search.includeHidden") }
                record(hiddenBtn?.isHiddenOrHasHiddenAncestor == false,
                       "Global search panel has a visible 'Include Hidden Files' toggle")
                panelWin.close()
            } else {
                record(false, "Global search panel has a visible 'Include Hidden Files' toggle")
            }
            try? await Task.sleep(for: .milliseconds(200))

            // M24: global hotkey registers + summon/hide toggle really works (the original preference is restored afterwards)
            let hadHotkey = UserDefaults.standard.string(forKey: GlobalHotkey.prefKey)
            GlobalHotkey.set(mods: [.control, .option, .shift], keyCode: 79, display: "⌃⌥⇧F18")
            record(GlobalHotkey.apply(), "Global hotkey registered (⌃⌥⇧F18 test combo)")
            // Deterministic preflight: explicitly activate and take key so that the first toggle's NSApp.isActive branch is reliably "hide"
            // (this assertion depends on app-active ambient state, unreliable after 40+ scenarios; the test builds its own precondition, not a product bug)
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(300))
            GlobalHotkey.toggle()   // frontmost → hide
            try? await Task.sleep(for: .milliseconds(350))
            let hiddenOK = NSApp.isHidden || !NSApp.isActive
            GlobalHotkey.toggle()   // background → summon to front
            try? await Task.sleep(for: .milliseconds(450))
            let backOK = NSApp.windows.contains { $0.isVisible && $0.windowController is MainWindowController }
            record(hiddenOK && backOK, "Global hotkey summon/hide toggle really works (hidden=\(hiddenOK) back=\(backOK))")
            if let hadHotkey { UserDefaults.standard.set(hadHotkey, forKey: GlobalHotkey.prefKey) }
            else { UserDefaults.standard.removeObject(forKey: GlobalHotkey.prefKey) }
            GlobalHotkey.apply()
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(200))

            // ── Scenario I-52: configurable landing spot for external/browser reveal (default is a new tab in the existing window, no new window) ──────────────
            // Placed after search (it opens and closes windows, and search must run in a clean window state); it restores the prior state for scenario 6.
            await runExternalOpenTargetScenario(delegate: delegate)
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(200))

            // Scenario 6 (I-21): layered ⌘W close + MRU fallback + reopen after closing the last window
            // 6a layering: with the settings window key, closeTopmost closes only the settings window and leaves workspaces alone
            SettingsWindowController.shared.showWindow(nil)
            try? await Task.sleep(for: .milliseconds(300))
            let wsCountBefore = wc.workspaces.count
            (NSApp.delegate as? AppDelegate)?.closeTopmost(nil)
            try? await Task.sleep(for: .milliseconds(200))
            record(SettingsWindowController.shared.window?.isVisible != true, "⌘W layering: closes the topmost settings window first")
            record(wc.workspaces.count == wsCountBefore, "⌘W layering: main window workspace not closed by mistake")
            // 6b MRU: create workspaces 2 and 3 (3 active) → switch back to 1 → ⌘W closes active 1 → should fall back to 3 (the previously active one)
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(200))
            wc.newWorkspaceTab(nil)
            wc.newWorkspaceTab(nil)
            wc.switchWorkspace(to: 0)
            (NSApp.delegate as? AppDelegate)?.closeTopmost(nil)
            try? await Task.sleep(for: .milliseconds(200))
            record(wc.workspaces.activeIndex == 1 && wc.workspaces.count == 2,
                   "⌘W close falls back via MRU to the previously active workspace")
            while wc.workspaces.count > 1 { wc.closeWorkspace(at: wc.workspaces.count - 1) }
            // 6c reopen: close the last window → a simulated Dock reactivation must open a new window
            window.performClose(nil)
            try? await Task.sleep(for: .milliseconds(300))
            _ = (NSApp.delegate as? AppDelegate)?
                .applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
            try? await Task.sleep(for: .milliseconds(400))
            let reopened = NSApp.windows.contains { $0.isVisible && $0.windowController is MainWindowController }
            record(reopened, "Dock reopen gives a window after the last one was closed")

            finish()
        }
    }

    // Keep each async scenario local so release compilation does not optimize one giant coroutine.

    private static func runInitialLayoutScenario(wc: MainWindowController, window: NSWindow, baseline: NSRect) async {
        let env = ProcessInfo.processInfo.environment
        // Scenario 1: view switches must never change the window size (regression assertion for a user-reported bug)
        let pane = wc.grid.activePane
        for (mode, name) in [(PaneViewMode.icons, "icons"), (.columns, "columns"), (.list, "list")] {
            pane.setViewMode(mode)
            try? await Task.sleep(for: .milliseconds(400))
            let same = window.frame.size == baseline.size
            record(same, "View switch [\(name)] keeps window size: \(Int(window.frame.width))x\(Int(window.frame.height))")
            capture(window, "01-viewmode-\(name)")
            // I-24b content-level assertion ("fills the area" is not enough, rows must really render): first column has >0 rows and the table has visible height
            if mode == .columns {
                let unit = pane.activeTab.columnVC?.columns.first
                let rows = unit?.tableView.numberOfRows ?? -1
                let tf = unit?.tableView.frame ?? .zero
                let clipW = unit?.tableView.superview?.frame.width ?? 0
                record(rows > 0 && tf.height > 20 && clipW > 100,
                       "First column content really renders (rows \(rows), table \(Int(tf.width))x\(Int(tf.height)), viewport width \(Int(clipW)))")
                // I-24b deep probe: per-layer frames + first column self-rendered to an image (to find the layer where content goes missing)
                if let unit, let colVC = pane.activeTab.columnVC {
                    var f: [String] = []
                    var v: NSView? = unit.tableView
                    while let cur = v, cur !== window.contentView {
                        f.append("\(type(of: cur)) \(Int(cur.frame.origin.x)),\(Int(cur.frame.origin.y)) \(Int(cur.frame.width))x\(Int(cur.frame.height)) hidden=\(cur.isHidden) win=\(cur.window != nil)")
                        v = cur.superview
                    }
                    Self.extraDump.append("I-24b layer chain (table→contentView):\n" + f.joined(separator: "\n") + "\ncolVC.view.frame=\(colVC.view.frame)")
                    try? ("I-24b layer chain (table→contentView):\n" + f.joined(separator: "\n")
                          + "\ncolVC.view.frame=\(colVC.view.frame)").data(using: .utf8)?
                        .write(to: outDir.appendingPathComponent("i24b-chain.txt"))
                    if let rep = unit.bitmapImageRepForCachingDisplay(in: unit.bounds) {
                        unit.cacheDisplay(in: unit.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?
                            .write(to: outDir.appendingPathComponent("24-column-unit.png"))
                    }
                }
            }
        }

        // Scenario 2: iterate the five layouts, window size unchanged + no crash
        for layout in PaneLayout.allCases {
            wc.grid.apply(layout: layout)
            try? await Task.sleep(for: .milliseconds(350))
            let same = window.frame.size == baseline.size
            record(same, "Layout [\(layout)] keeps window size")
        }
        wc.grid.apply(layout: .dualH)
        capture(window, "02-layout-dualH")

        // Scenario 3: task status window: the empty state must have explanatory text, never blank
        let progress = ProgressWindowController.shared
        progress.toggleVisible(nil)
        try? await Task.sleep(for: .milliseconds(300))
        let shown = progress.window?.isVisible == true
        record(shown, "Task window can open")
        if let pw = progress.window {
            capture(pw, "03-tasks-empty")
            // Empty-state label visibility is probed through the view tree
            let hasVisibleText = viewTree(pw.contentView).contains {
                ($0 as? NSTextField).map { !$0.isHidden && !$0.stringValue.isEmpty } ?? false
            }
            record(hasVisibleText, "Task window empty state has text (not blank)")
        }
        progress.toggleVisible(nil)

        // Scenario 4: stash shelf: add programmatically (same code path as drag and drop), card pile/count shown
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hspace-uitest-\(UUID().uuidString).txt")
        try? Data("x".utf8).write(to: tmp)
        wc.sidebar.model.stash?.add([tmp])
        try? await Task.sleep(for: .milliseconds(500))
        let stashCount = wc.sidebar.model.stash?.items.count ?? 0
        record(stashCount >= 1, "Added to stash (\(stashCount) items)")
        capture(window, "04-stash")
        // Cleanup: this test's item + leftovers from past runs (uitest prefix or stale target); never pollute the user's real stash
        if let stash = wc.sidebar.model.stash {
            let junk = stash.items.compactMap { item -> UUID? in
                guard let url = stash.store.resolve(item) else { return item.id }  // stale item
                return url.lastPathComponent.hasPrefix("hspace-uitest-") ? item.id : nil
            }
            stash.remove(ids: junk)
        }
        try? FileManager.default.removeItem(at: tmp)

        // ── Scenario M17: custom-drawn deck + full-height sidebar + workspace migration (§5 acceptance gate) ──────────
        window.contentView?.layoutSubtreeIfNeeded()

        // M17-1: no NSToolbar (I-10 tracking-separator system is gone)
        record(window.toolbar == nil, "No NSToolbar (custom-drawn deck)")

        // M17-2: deck row heights 40 / 36
        let tabH = wc.deck.tabRow.frame.height
        let toolH = wc.deck.toolbarRow.frame.height
        record(abs(tabH - TopDeckView.tabRowHeight) < 1.5, "Deck tab row height 40 (got \(Int(tabH)))")
        record(abs(toolH - TopDeckView.toolbarRowHeight) < 1.5, "Deck toolbar row height 36 (got \(Int(toolH)))")

        // M17-3: workspace tab bar exists (deck view tree contains workspaceTabBar) + starts with a single workspace
        let hasTabBar = viewTree(window.contentView).contains { $0 === wc.deck.workspaceTabBar }
        record(hasTabBar, "Workspace tab bar exists in the deck")
        record(wc.workspaceCount == 1, "Starts with a single workspace (\(wc.workspaceCount))")

        // M22: version badge (no update state) exists in the deck tab bar + its text is "v{short version}" (no ↑)
        let badge = wc.deck.versionBadge
        let badgeInTree = viewTree(window.contentView).contains { $0 === badge }
        record(badgeInTree, "Version badge exists in the deck tab bar")
        let badgeLabel = viewTree(badge).compactMap { ($0 as? NSTextField)?.stringValue }
            .first { $0.hasPrefix("v") } ?? ""
        record(badgeLabel == "v\(AppVersion.shortVersion)" && !badgeLabel.contains("↑"),
               "Version badge has no update-state text v\(AppVersion.shortVersion) (got '\(badgeLabel)')")
        capture(window, "14-version-badge")

        // M17-4: ⌘T adds / ⌘W closes correctly
        wc.newWorkspaceTab(nil)
        try? await Task.sleep(for: .milliseconds(250))
        let afterNew = wc.workspaceCount
        record(afterNew == 2, "⌘T new workspace → 2 (got \(afterNew))")
        capture(window, "06-workspaces-2")
        wc.closeActiveWorkspace(nil)
        try? await Task.sleep(for: .milliseconds(250))
        let afterClose = wc.workspaceCount
        record(afterClose == 1, "⌘W close workspace → 1 (got \(afterClose))")

        // M17-5: full-height divider (sidebarColumn.height == contentView.height)
        let contentH = window.contentView?.frame.height ?? 0
        let sideH = wc.sidebarColumnFrame.height
        record(abs(sideH - contentH) < 2,
               "Sidebar column spans full height: column \(Int(sideH)) == content \(Int(contentH))")

        // M17-6: 3 sidebar collapse/expand rounds, window size and right column layout do not drift (I-10 regression)
        wc.setSidebar(collapsed: false)  // Start from a known expanded state
        try? await Task.sleep(for: .milliseconds(250))
        window.contentView?.layoutSubtreeIfNeeded()
        let sizeBefore = window.frame.size
        let contentXBefore = wc.contentColumnFrame.minX
        var driftFree = true
        var driftDetail = ""
        for i in 0..<3 {
            wc.setSidebar(collapsed: true)   // collapse
            try? await Task.sleep(for: .milliseconds(220))
            window.contentView?.layoutSubtreeIfNeeded()
            wc.setSidebar(collapsed: false)  // expand back to the original state
            try? await Task.sleep(for: .milliseconds(220))
            window.contentView?.layoutSubtreeIfNeeded()
            if window.frame.size != sizeBefore { driftFree = false; driftDetail += " [round \(i) size \(Int(window.frame.width))x\(Int(window.frame.height))]" }
            if abs(wc.contentColumnFrame.minX - contentXBefore) > 2 { driftFree = false; driftDetail += " [round \(i) right columnX \(Int(contentXBefore))→\(Int(wc.contentColumnFrame.minX))]" }
        }
        record(driftFree, "3 collapse/expand rounds: window size and right column layout do not drift\(driftDetail)")

        // I-22: collapse via button → clicking again must really expand (sidebar visible with width ≥160, not just a moved divider)
        wc.toggleSidebar(nil)   // collapse (same path as the deck sidebar button: deckToggleSidebar→toggleSidebar)
        try? await Task.sleep(for: .milliseconds(220))
        window.contentView?.layoutSubtreeIfNeeded()
        let collapsedOK = wc.sidebarWrap.frame.width < 1 || wc.sidebarWrap.isHidden
        wc.toggleSidebar(nil)   // click again to expand
        try? await Task.sleep(for: .milliseconds(220))
        window.contentView?.layoutSubtreeIfNeeded()
        let reopenedOK = !wc.sidebarWrap.isHidden && wc.sidebarWrap.frame.width >= 160
        record(collapsedOK && reopenedOK,
               "Sidebar button really expands after collapsing (width \(Int(wc.sidebarWrap.frame.width)), hidden=\(wc.sidebarWrap.isHidden))")

        // I-26: header sorting really works on all six columns, via the same sortDescriptors chain as a header click, checked in both directions
        let sortListVC = wc.grid.activePane.activeTab.listVC
        for key in SortSpec.Key.allCases {
            sortListVC.tableView.sortDescriptors = [NSSortDescriptor(key: key.rawValue, ascending: false)]
            try? await Task.sleep(for: .milliseconds(120))
            let descOK = sortListVC.model.sort.key == key && sortListVC.model.sort.ascending == false
            sortListVC.tableView.sortDescriptors = [NSSortDescriptor(key: key.rawValue, ascending: true)]
            try? await Task.sleep(for: .milliseconds(120))
            let ascOK = sortListVC.model.sort.key == key && sortListVC.model.sort.ascending == true
            record(descOK && ascOK, "Column header sort really works [\(key.rawValue)] (descending/ascending)")
        }
        sortListVC.tableView.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        try? await Task.sleep(for: .milliseconds(150))

        // I-27: "opening" a directory always navigates in-app (QSpace semantics; sandbox fixture, never touches real files)
        let openSandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("hspace-uitest-open-\(UUID().uuidString)", isDirectory: true)
        let openChild = openSandbox.appendingPathComponent("Überordner", isDirectory: true)
        try? FileManager.default.createDirectory(at: openChild, withIntermediateDirectories: true)
        let openPane = wc.grid.activePane
        openPane.navigate(to: openSandbox)
        try? await Task.sleep(for: .milliseconds(500))
        let openListVC = openPane.activeTab.listVC
        if let idx = openListVC.model.items.firstIndex(where: { $0.name == "Überordner" }) {
            openListVC.tableView.selectRowIndexes([idx], byExtendingSelection: false)
            openListVC.openSelected(nil)   // same path as context "Open" / ⌘O
            try? await Task.sleep(for: .milliseconds(400))
            let landed = openPane.activeTab.browser.current.standardizedFileURL.path
            record(landed == openChild.standardizedFileURL.path,
                   "Directory context Open = in-app navigation (landed on \(landed.hasSuffix("Überordner") ? "Überordner" : landed))")
        } else {
            record(false, "Directory context Open = in-app navigation (fixture row not found)")
        }
        openPane.navigate(to: FileManager.default.homeDirectoryForCurrentUser)
        try? await Task.sleep(for: .milliseconds(300))
        try? FileManager.default.removeItem(at: openSandbox)

        // M17-7: stash shelf contentGroup centered (|center offset| ≤ 2pt, I-07 regression)
        let tmp2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("hspace-uitest-\(UUID().uuidString).txt")
        try? Data("y".utf8).write(to: tmp2)
        wc.sidebar.model.stash?.add([tmp2])
        try? await Task.sleep(for: .milliseconds(450))
        window.contentView?.layoutSubtreeIfNeeded()
        let offset = wc.sidebar.stashShelfView.contentGroupCenterOffsetX
        record(abs(offset) <= 2, "Stash shelf contentGroup centered (offset \(String(format: "%.1f", offset))pt)")
        // §6.3 B2: action bar hidden at rest (revealed on hover) + the floating bar is an overlay outside the main Auto Layout chain
        record(wc.sidebar.stashShelfView.actionBarHidden, "Stash shelf action bar hidden at rest (hover-reveal)")
        record(wc.sidebar.stashShelfView.actionBarIsOverlay, "Stash shelf floating bar is an overlay (outside main chain layout)")
        if let stash = wc.sidebar.model.stash {
            let junk = stash.items.compactMap { item -> UUID? in
                guard let url = stash.store.resolve(item) else { return item.id }
                return url.lastPathComponent.hasPrefix("hspace-uitest-") ? item.id : nil
            }
            stash.remove(ids: junk)
        }
        try? FileManager.default.removeItem(at: tmp2)

        // Public asset sanitization channel (I-35): HSPACE_UITEST_DEMO=demo directory → navigate all panes to the demo data before screenshots,
        // so public screenshots such as the README's show no real file names
        if let demo = env["HSPACE_UITEST_DEMO"], !demo.isEmpty {
            let demoURL = URL(fileURLWithPath: demo)
            wc.grid.apply(layout: .dualH)
            try? await Task.sleep(for: .milliseconds(250))
            for p in wc.grid.visiblePanes { p.navigate(to: demoURL) }
            try? await Task.sleep(for: .milliseconds(600))
        }

        // M17 screenshot matrix: single/dual/quad panes + collapsed state + dark/light appearance (human check for clipping/misalignment)
        wc.setSidebar(collapsed: false)  // Full-height sidebar visible (expanded state)
        try? await Task.sleep(for: .milliseconds(250))
        for (layout, name) in [(PaneLayout.single, "single"), (.dualH, "dual"), (.quad, "quad")] {
            wc.grid.apply(layout: layout)
            try? await Task.sleep(for: .milliseconds(320))
            window.contentView?.layoutSubtreeIfNeeded()
            capture(window, "10-deck-\(name)")
        }
        wc.grid.apply(layout: .dualH)
        wc.setSidebar(collapsed: true)  // Collapsed-state screenshot (traffic lights make way)
        try? await Task.sleep(for: .milliseconds(320))
        window.contentView?.layoutSubtreeIfNeeded()
        capture(window, "11-deck-collapsed")
        wc.setSidebar(collapsed: false)  // Restore expanded
        try? await Task.sleep(for: .milliseconds(250))
        // Appearance matrix (expanded state, deck material dark/light)
        let savedAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try? await Task.sleep(for: .milliseconds(300))
        window.contentView?.layoutSubtreeIfNeeded()
        capture(window, "12-deck-dark")
        NSApp.appearance = NSAppearance(named: .aqua)
        try? await Task.sleep(for: .milliseconds(300))
        window.contentView?.layoutSubtreeIfNeeded()
        capture(window, "13-deck-light")
        NSApp.appearance = savedAppearance

        // ── Scenario M21: monospaced digit column alignment + selection pill rendering (list mode) ───────────────
        wc.grid.apply(layout: .single)
        pane.setViewMode(.list)
        try? await Task.sleep(for: .milliseconds(450))
        window.contentView?.layoutSubtreeIfNeeded()
        capture(window, "20-list-columns")          // Human check: size/date columns monospaced and aligned + unit gray levels
        let pillVisible = pane.uiTestSelectFirstItemsAndPillVisible(2)
        try? await Task.sleep(for: .milliseconds(250))
        window.contentView?.layoutSubtreeIfNeeded()
        record(pillVisible, "List selection → status bar accent pill visible")
        capture(window, "21-status-pill")           // Human check: "N selected · size" pill rendering
        // One more shot in dark mode (verifies the 10% accent pill background re-resolves for light/dark)
        let savedAppr2 = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try? await Task.sleep(for: .milliseconds(300))
        window.contentView?.layoutSubtreeIfNeeded()
        capture(window, "22-status-pill-dark")
        NSApp.appearance = savedAppr2
    }

    private static func runFileOperationsScenario(wc: MainWindowController, window: NSWindow) async {
        let pane = wc.grid.activePane
        let progress = ProgressWindowController.shared
        // ── Scenario M23: full-feature self-test matrix: every assertion checks the "real effect", not "did not crash" ──────────
        // (user lesson 2026-08-26: the collapse assertion checked size only, not real visibility).
        // All of it sits before scenario 5 (search): the main window must stay alive; closing/reopening windows is in the final scenario 6.
        let fs = FileManager.default

        // M23-1: view mode switch → the matching content view is really in the window hierarchy and visible (not just a window size check)
        wc.grid.apply(layout: .single)
        try? await Task.sleep(for: .milliseconds(300))
        // Reuses the pane from scenario 1 (pool[0]; after a layout switch activePaneIndex returns to 0, the same pane)
        for (mode, name) in [(PaneViewMode.list, "list"), (.icons, "icons"), (.columns, "columns")] {
            pane.setViewMode(mode)
            try? await Task.sleep(for: .milliseconds(350))
            window.contentView?.layoutSubtreeIfNeeded()
            let tab = pane.activeTab
            let v: NSView?
            switch mode {
            case .list: v = tab.listVC.view
            case .icons: v = tab.iconVC?.view
            case .columns: v = tab.columnVC?.view
            }
            let inTree = v.map { view in viewTree(window.contentView).contains { $0 === view } } ?? false
            // Really visible: not hidden, and really fills the content area (width and height both >1); the column view collapsing to 220×1/696×1 was caught here (since fixed)
            let visible = (v?.isHiddenOrHasHiddenAncestor == false)
                && (v?.frame.width ?? 0) > 1 && (v?.frame.height ?? 0) > 1
            record(inTree && visible, "View mode [\(name)] matching view really in hierarchy and visible (\(Int(v?.frame.width ?? 0))x\(Int(v?.frame.height ?? 0)))")
        }
        // Human-check evidence for the column view collapse fix (single-pane layout; the column view must fill the right column, not shrink to 220×1/696×1)
        try? await Task.sleep(for: .milliseconds(700))   // Wait for columns to load their content asynchronously before the screenshot
        window.contentView?.layoutSubtreeIfNeeded()
        capture(window, "23-columns-single")

        // M23-2: layout switch → really shows the matching pane count (not just a window size check)
        wc.grid.apply(layout: .quad)
        try? await Task.sleep(for: .milliseconds(350))
        window.contentView?.layoutSubtreeIfNeeded()
        record(wc.grid.visiblePanes.count == 4, "Layout quad really shows 4 panes (got \(wc.grid.visiblePanes.count))")
        wc.grid.apply(layout: .single)
        try? await Task.sleep(for: .milliseconds(350))
        record(wc.grid.visiblePanes.count == 1, "Layout single really shows 1 pane (got \(wc.grid.visiblePanes.count))")

        // Sandbox (real file system fixture; cleaned up after the test, never pollutes user directories)
        let sandbox = fs.temporaryDirectory
            .appendingPathComponent("hspace-uitest-m23-\(UUID().uuidString)")
        let child = sandbox.appendingPathComponent("child")
        try? fs.createDirectory(at: child, withIntermediateDirectories: true)
        let child2 = sandbox.appendingPathComponent("child2")   // I-39: distinguishes "selection-driven" from "history fallback"
        try? fs.createDirectory(at: child2, withIntermediateDirectories: true)

        // M23-3: navigate back/forward/up → the path really changed (not just "did not crash")
        pane.setViewMode(.list)
        try? await Task.sleep(for: .milliseconds(200))
        pane.navigate(to: sandbox)
        try? await Task.sleep(for: .milliseconds(250))
        record(samePath(pane.activeTab.browser.current, sandbox), "Navigation into sandbox takes effect")
        pane.navigate(to: child)
        try? await Task.sleep(for: .milliseconds(250))
        record(samePath(pane.activeTab.browser.current, child), "Navigation into subdirectory takes effect")
        pane.goBack(nil)
        try? await Task.sleep(for: .milliseconds(250))
        record(samePath(pane.activeTab.browser.current, sandbox), "Navigation back really returns to parent")
        pane.goForward(nil)
        try? await Task.sleep(for: .milliseconds(250))
        record(samePath(pane.activeTab.browser.current, child), "Navigation forward really restores the path")
        pane.goUpFolder(nil)
        try? await Task.sleep(for: .milliseconds(250))
        record(samePath(pane.activeTab.browser.current, sandbox), "Navigation up really goes to parent")

        // I-39: ⌘↑ auto-selects the child it came from, ⌘↓ is its inverse (selection-driven first; with no selection, falls back to the direct child from history)
        var upSelectsChild = false
        for _ in 0..<10 {
            if pane.activeTab.listVC.selectedURLs.contains(where: { samePath($0, child) }) {
                upSelectsChild = true
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        record(upSelectsChild, "I-39 ⌘↑ auto-selects the originating child after going up")
        // Anti-false-green design: history holds child, so we deliberately select child2. If ⌘↓ quietly took the history fallback it would land on child;
        // landing on child2 proves the "enter selection" main path really works (a converged end-state assertion once went falsely green here)
        pane.activeTab.listVC.select(urls: [child2])
        pane.goDownFolder(nil)
        try? await Task.sleep(for: .milliseconds(250))
        record(samePath(pane.activeTab.browser.current, child2),
               "I-39 ⌘↓ enters the selected folder (selection-driven, not history fallback)")
        pane.goUpFolder(nil)
        try? await Task.sleep(for: .milliseconds(250))
        pane.activeTab.listVC.select(urls: [])   // Clear selection → checks the "no selection falls back to direct child from history" path
        pane.goDownFolder(nil)
        try? await Task.sleep(for: .milliseconds(250))
        record(samePath(pane.activeTab.browser.current, child2), "I-39 ⌘↓ with no selection falls back to the most recent direct child in history")
        pane.goUpFolder(nil)   // Back to the sandbox (later scenarios assume they start here)
        try? await Task.sleep(for: .milliseconds(250))
        // Guard truth: a disabled ⌘↓ leaking to the table view must be swallowed (the original bug = NSTableView's default jump-select);
        // send the key event straight to the table (bypassing the menu); neither selection nor path may change
        let guardTable = pane.activeTab.listVC.tableView
        let selBefore = guardTable.selectedRowIndexes
        let pathBefore = pane.activeTab.browser.current
        if let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                                     timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                     characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
                                     isARepeat: false, keyCode: 125) {
            guardTable.keyDown(with: ev)
        }
        record(guardTable.selectedRowIndexes == selBefore
               && samePath(pane.activeTab.browser.current, pathBefore),
               "I-39 ⌘↓ reaching the table view is swallowed without jump-select (guard really works)")

        // M23-5: show-hidden-files toggle → really flips the model state
        let h0 = pane.activeTab.model.includeHidden
        pane.activeTab.listVC.toggleHiddenFiles(nil)
        try? await Task.sleep(for: .milliseconds(200))
        let h1 = pane.activeTab.model.includeHidden
        pane.activeTab.listVC.toggleHiddenFiles(nil)
        try? await Task.sleep(for: .milliseconds(150))
        let h2 = pane.activeTab.model.includeHidden
        record(h1 == !h0 && h2 == h0, "Show-hidden-files toggle really flips model state")

        // M23-7: new folder/duplicate/rename/move to Trash → really run coordinator/kernel + assert the file system result
        // Hard rule (user 2026-08-26): pass the sandbox guard before each mutating operation; on guard failure, skip it (never hit real files)
        let folderName = L10n.t("newItem.folder")
        let newFolderURL = sandbox.appendingPathComponent(folderName)
        let gNewFolder = assertSandboxed(sandbox)
        record(gNewFolder, "Sandbox guard: new folder target inside own fixture")
        if gNewFolder { wc.coordinator.newFolder(in: sandbox, revealIn: nil) }
        let created = gNewFolder ? (await pollFS { fs.fileExists(atPath: newFolderURL.path) }) : false
        record(created, "New folder really written to disk (sandbox contains '\(folderName)')")

        let dupSrc = sandbox.appendingPathComponent("dup-src.txt")
        let gDup = assertSandboxed(dupSrc)
        record(gDup, "Sandbox guard: duplicate source inside own fixture")
        if gDup { try? Data("z".utf8).write(to: dupSrc); wc.coordinator.duplicate([dupSrc]) }
        let duped = gDup ? (await pollFS {
            let names = (try? fs.contentsOfDirectory(atPath: sandbox.path)) ?? []
            return names.filter { $0.hasPrefix("dup-src") }.count >= 2
        }) : false
        record(duped, "Duplicate really written to disk (dup-src appears ≥2 times)")

        let renamedName = "hspace-uitest-renamed-\(UUID().uuidString.prefix(8))"
        let renamedURL = sandbox.appendingPathComponent(renamedName)
        let gRename = assertSandboxed(newFolderURL) && assertSandboxed(renamedURL)
        record(gRename, "Sandbox guard: rename target inside own fixture")
        if gRename { wc.coordinator.rename(newFolderURL, to: renamedName) { _ in } }
        let renamed = gRename ? (await pollFS {
            !fs.fileExists(atPath: newFolderURL.path) && fs.fileExists(atPath: renamedURL.path)
        }) : false
        record(renamed, "Rename really takes effect (new name exists, old name gone)")

        let gTrash = assertSandboxed(renamedURL)
        record(gTrash, "Sandbox guard: move-to-Trash target inside own fixture")
        if gTrash { wc.coordinator.moveToTrash([renamedURL]) }
        let trashed = gTrash ? (await pollFS { !fs.fileExists(atPath: renamedURL.path) }) : false
        record(trashed, "Move to Trash really takes effect (gone from source directory)")
        // Clean up the test item that landed in the user's Trash (unique name, safe)
        let trashDir = fs.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        if let entries = try? fs.contentsOfDirectory(atPath: trashDir.path) {
            for e in entries where e.hasPrefix(renamedName) {
                try? fs.removeItem(at: trashDir.appendingPathComponent(e))
            }
        }

        // M23-8: Copy Path → assert clipboard content (through the real listVC.copyPath → coordinator.copyPaths chain)
        pane.activeTab.model.reload()
        _ = await pollFS { pane.activeTab.model.items.contains { $0.url.lastPathComponent == "dup-src.txt" } }
        window.contentView?.layoutSubtreeIfNeeded()
        let srcItem = pane.activeTab.model.items.first { $0.url.lastPathComponent == "dup-src.txt" }
        if let srcItem {
            pane.activeTab.listVC.select(urls: [srcItem.url])
            try? await Task.sleep(for: .milliseconds(150))
            pane.activeTab.listVC.copyPath(nil)
            try? await Task.sleep(for: .milliseconds(150))
            let clip = NSPasteboard.general.string(forType: .string)
            record(clip == srcItem.url.path, "Copy Path → clipboard content correct")
        } else {
            record(false, "Copy Path → clipboard content correct")
        }

        // M23-9: context menu construction → item count + key items present + enabled state honestly follows the selection
        let selection = pane.activeTab.listVC.selectedItems
        let listVC = pane.activeTab.listVC
        let itemMenu = FileContextMenuBuilder.menu(selection: selection, directory: sandbox, target: listVC)
        let actions = Set(itemMenu.items.compactMap { $0.action })
        let keyActions: [Selector] = [
            #selector(FileListViewController.openSelected(_:)),
            #selector(FileListViewController.copyItems(_:)),
            #selector(FileListViewController.cutItems(_:)),
            #selector(FileListViewController.pasteItems(_:)),
            #selector(FileListViewController.copyPath(_:)),
            #selector(FileListViewController.renameSelected(_:)),
            #selector(FileListViewController.duplicateItems(_:)),
            #selector(FileListViewController.moveToTrash(_:)),
            #selector(FileListViewController.compressItems(_:)),
            #selector(FileListViewController.newFolderHere(_:)),
            #selector(FileListViewController.getInfo(_:)),
            #selector(FileListViewController.openInTerminal(_:)),
        ]
        record(keyActions.allSatisfy { actions.contains($0) },
               "Item context menu has all key items (\(itemMenu.items.count) items)")
        // Honest disabling: plain text selection → no 'Extract' item
        record(!actions.contains(#selector(FileListViewController.extractItems(_:))),
               "Item context menu honestly disabled: non-archive selection has no 'Extract' item")
        // enabled follows selection: with selection → Copy enabled; selection cleared → disabled
        let copyItem = itemMenu.items.first { $0.action == #selector(FileListViewController.copyItems(_:)) }
        let enabledWithSel = copyItem.map { listVC.validateMenuItem($0) } ?? false
        listVC.select(urls: [])
        try? await Task.sleep(for: .milliseconds(120))
        let disabledNoSel = copyItem.map { listVC.validateMenuItem($0) == false } ?? false
        record(enabledWithSel && disabledNoSel, "Context 'Copy' enabled state follows selection correctly")
        // Directory menu for the blank area
        let dirMenu = FileContextMenuBuilder.menu(selection: [], directory: sandbox, target: listVC)
        let dirActions = Set(dirMenu.items.compactMap { $0.action })
        // Since v0.19.20 "New File" was added (user report: no blank area to right-click when content fills the view) → 5 items became 6
        let dirKey = dirActions.contains(#selector(FileListViewController.newFolderHere(_:)))
            && dirActions.contains(#selector(FileListViewController.newFileHere(_:)))
            && dirActions.contains(#selector(FileListViewController.pasteItems(_:)))
            && dirActions.contains(#selector(FileListViewController.getInfo(_:)))
            && dirActions.contains(#selector(FileListViewController.openInTerminal(_:)))
        record(dirMenu.items.count == 6 && dirKey,
               "Blank-area directory menu has 6 items including new folder/new file/paste/info/terminal (got \(dirMenu.items.count))")

        // M23-10: task window manual toggle → really visible/hidden (not just "did not crash"); reuses progress from scenario 3
        progress.toggleVisible(nil)
        try? await Task.sleep(for: .milliseconds(250))
        record(progress.window?.isVisible == true, "Task window manual open → visible")
        progress.toggleVisible(nil)
        try? await Task.sleep(for: .milliseconds(250))
        record(progress.window?.isVisible != true, "Task window manual close → hidden")

        // M23-11: ⌘I info panel → window appears and can be closed
        let infoBase = sandbox.lastPathComponent
        listVC.getInfo(nil)   // No selection → targets the current directory (the sandbox)
        try? await Task.sleep(for: .milliseconds(300))
        let infoWin = NSApp.windows.first { w in
            w.isVisible && !(w.windowController is MainWindowController) && w.title.contains(infoBase)
        }
        record(infoWin != nil, "Get Info panel appears")
        if let infoWin {
            infoWin.performClose(nil)
            try? await Task.sleep(for: .milliseconds(250))
            record(infoWin.isVisible == false, "Get Info panel can be closed")
        } else {
            record(false, "Get Info panel can be closed")
        }
        window.makeKeyAndOrderFront(nil)

        // M23-12: each settings plugin page makeView → no ambiguous constraints + key controls exist
        for page in SettingsPages.extraPages {
            let v = page.makeView()
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 460))
            v.frame = host.bounds
            v.autoresizingMask = [.width, .height]
            host.addSubview(v)
            host.layoutSubtreeIfNeeded()
            let tree = viewTree(v)
            let ambiguous = tree.contains { $0.hasAmbiguousLayout }
            let hasControl = tree.contains { $0 is NSButton || $0 is NSPopUpButton || $0 is NSSlider }
            record(!ambiguous && hasControl,
                   "Settings page [\(page.pageTitleKey)] makeView has no ambiguous constraints and has key controls")
        }

        // M23-13: shortcut registry default bindings read correctly (externalized config source of truth)
        let dispGlobal = KeyBindings.display("searchGlobal")
        let dispInfo = KeyBindings.display("getInfo")
        record(dispGlobal == "⇧⌘F" && dispInfo == "⌘I",
               "Shortcut registry default bindings read correctly (global search ⇧⌘F / Get Info ⌘I)")

        // M23-14: sidebar has the bookmarks group with seeded bookmark rows (seeded asynchronously, short poll)
        var bmCount = 0
        for _ in 0..<20 {
            if let g = wc.sidebar.model.groups.first(where: { $0.kind == .bookmarks }),
               g.children.count >= 1 { bmCount = g.children.count; break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        record(bmCount >= 1, "Sidebar has bookmarks group and seeded bookmark rows ≥1 (\(bmCount))")

        // M23-15 (I-31): search result row context menu → items>0 + has 'Copy Path' + clipboard == the path after running it (real effect)
        // After onReveal/onStash are injected through the real chain (wc.showSearchGlobal → SearchPanelController.show),
        // build a SearchHit from a real fixture URL and call menu(for:), verifying the menu trimmed for the search context has content and a working Copy Path.
        wc.showSearchGlobal(nil)
        try? await Task.sleep(for: .milliseconds(200))
        let searchHit = SearchHit(url: sandbox, name: sandbox.lastPathComponent,
                                  isDirectory: true, size: nil, modified: nil, contentTypeID: nil)
        let searchMenu = SearchPanelController.shared.menu(for: searchHit)
        let copyPathTitle = L10n.t("menu.copyPath")
        let hasCopyPath = searchMenu.items.contains { $0.title == copyPathTitle }
        record(searchMenu.items.count > 0 && hasCopyPath,
               "Search result context menu items>0 and has 'Copy Path' (\(searchMenu.items.count) items)")
        // Reveal chain + stash shelf reachable → matching items exist (FG-1: show only if reachable)
        record(searchMenu.items.contains { $0.title == L10n.t("search.reveal") }
               && searchMenu.items.contains { $0.title == L10n.t("search.addToStash") }
               && searchMenu.items.contains { $0.title == L10n.t("menu.getInfo") },
               "Search result context menu has reveal/add to stash/Get Info (all reachable items present)")
        // Real effect: run 'Copy Path' → clipboard content == the URL path
        if let cp = searchMenu.items.first(where: { $0.title == copyPathTitle }) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("SENTINEL-\(UUID().uuidString)", forType: .string)
            _ = cp.target?.perform(cp.action, with: cp)
            try? await Task.sleep(for: .milliseconds(120))
            let clip = NSPasteboard.general.string(forType: .string)
            record(clip == sandbox.path, "Search result context 'Copy Path' → clipboard content == that path")
        } else {
            record(false, "Search result context 'Copy Path' → clipboard content == that path")
        }
        // I-38/I-40: result stream does not disturb selection + local search ranks nearest-to-root first + path column always shown (fixture drives the real appendResults chain)
        let sp = SearchPanelController.shared
        func fixtureHit(_ rel: String) -> SearchHit {
            let u = URL(fileURLWithPath: sandbox.path + "/" + rel)
            return SearchHit(url: u, name: u.lastPathComponent, isDirectory: false,
                             size: 1, modified: nil, contentTypeID: nil)
        }
        sp.uiTestReset(root: sandbox)
        sp.uiTestAppend([fixtureHit("deep/deeper/c.txt"), fixtureHit("a.txt"), fixtureHit("deep/b.txt")])
        let wantOrder = ["a.txt", "deep/b.txt", "deep/deeper/c.txt"].map { sandbox.path + "/" + $0 }
        record(sp.uiTestResultPaths == wantOrder, "I-40 local search ranks nearest-to-root first (direct children first)")
        record(sp.uiTestFirstRowPathCellText?.isEmpty == false, "I-40 result table always shows a rendered parent path column")
        sp.uiTestSelectRow(1)                    // selects deep/b.txt
        sp.uiTestAppend([fixtureHit("aa.txt")])  // new batch inserts ahead → row numbers shift
        // Same-level lexicographic tiebreaker, full order check (a.txt before aa.txt; this goes red if the comparator is reversed or removed)
        let wantOrder2 = ["a.txt", "aa.txt", "deep/b.txt", "deep/deeper/c.txt"]
            .map { sandbox.path + "/" + $0 }
        record(sp.uiTestResultPaths == wantOrder2, "I-40 same-level lexicographic order (a.txt before aa.txt, full order check)")
        record(sp.uiTestSelectedPath == sandbox.path + "/deep/b.txt",
               "I-38 selection neither lost nor drifts when a new streamed batch arrives (row shift, still locked to the same URL)")
        // Symlink convention: the Spotlight channel reports resolved paths (/var→/private/var);
        // with an unresolved root, hits must still sort by depth and not all sink to the bottom (a main-channel defect confirmed in review)
        let resolvedBase = sandbox.resolvingSymlinksInPath().path
        if resolvedBase != sandbox.path {
            sp.uiTestAppend([SearchHit(url: URL(fileURLWithPath: resolvedBase + "/deep/rr.txt"),
                                       name: "rr.txt", isDirectory: false,
                                       size: 1, modified: nil, contentTypeID: nil)])
            let rrIndex = sp.uiTestResultPaths.firstIndex { $0.hasSuffix("/deep/rr.txt") }
            record(rrIndex != nil && rrIndex! < sp.uiTestResultPaths.count - 1
                   && sp.uiTestResultPaths.last?.hasSuffix("/deep/deeper/c.txt") == true,
                   "I-40 resolved-path hits still sort by depth (symlink root does not break it)")
        } else {
            record(true, "I-40 resolved-path hits still sort by depth (symlink root does not break it)")   // no symlink difference on this machine: the conventions naturally agree
        }
        // Out-of-root hits sink to the bottom (truth of the .max fallback branch): paths outside the sandbox must sort last
        sp.uiTestAppend([SearchHit(url: URL(fileURLWithPath: fs.temporaryDirectory.path
                                                + "/hspace-uitest-outside.txt"),
                                   name: "hspace-uitest-outside.txt", isDirectory: false,
                                   size: 1, modified: nil, contentTypeID: nil)])
        record(sp.uiTestResultPaths.last?.hasSuffix("/hspace-uitest-outside.txt") == true,
               "I-40 out-of-root hit sinks to the last row")
        // I-42 hang regression: streaming accumulation of a large result set must be O(n) and not stall (the old `hits+visible` rebuilt everything per batch = O(n²) → hang).
        // Feed maxResults hits (in batches of 50 to simulate the stream); must finish within the limit + show the truncation notice at the cap.
        sp.uiTestReset(root: nil)
        let big = SearchLimits.maxResults
        let t0 = Date()
        var fed = 0
        while fed < big {
            let n = min(50, big - fed)
            sp.uiTestAppend((0..<n).map { j in
                SearchHit(url: URL(fileURLWithPath: "/tmp/hspace-i42/\(fed + j).txt"),
                          name: "\(fed + j).txt", isDirectory: false, size: 1, modified: nil, contentTypeID: nil)
            })
            fed += n
        }
        let elapsed = Date().timeIntervalSince(t0)
        record(elapsed < 3.0 && sp.uiTestResultCount == big,
               "I-42 large streamed accumulation is O(n) without stalling (fed \(big) hits in \(String(format: "%.2f", elapsed))s < 3s)")
        record(sp.uiTestTruncationVisible, "I-42 at the result cap shows the 'first N only' truncation notice")
        sp.uiTestReset(root: nil)
        // Live screenshot: path column + nearest-to-root ranking + selection kept (for final human review)
        if let spWin = NSApp.windows.first(where: { w in
            w.isVisible && !(w.windowController is MainWindowController) &&
            viewTree(w.contentView).contains { ($0 as? NSButton)?.title == L10n.t("search.includeHidden") }
        }) {
            capture(spWin, "05c-search-path-rank")
        }
        sp.uiTestReset(root: nil)

        // ── I-34: size column does not wrap when narrow (single line + head truncation, so an attributed string cannot overflow the 22pt row) ──
        let i34cell = TextCellView(identifier: .init("i34-size"))
        i34cell.configureSize(value: "151.4", unit: "MB", alignment: .right)
        record(i34cell.textField?.usesSingleLineMode == true
               && i34cell.textField?.lineBreakMode == .byTruncatingHead,
               "I-34 size column stays on one line (usesSingleLineMode + head truncation)")

        // ── M27 conflict experience: three buttons + per-folder batch resolution via the "apply to this folder" checkbox + custom-drawn panel screenshot ──
        // Fixture spans two folders: folderA has two conflicts, folderB one → the checkbox batch applies to one folder at a time.
        let folderA = sandbox.appendingPathComponent("conflictA")
        let folderB = sandbox.appendingPathComponent("conflictB")
        try? fs.createDirectory(at: folderA, withIntermediateDirectories: true)
        try? fs.createDirectory(at: folderB, withIntermediateDirectories: true)
        let a1 = folderA.appendingPathComponent("a1.txt")
        let a2 = folderA.appendingPathComponent("a2.txt")
        let b1 = folderB.appendingPathComponent("b1.txt")
        for u in [a1, a2, b1] { try? Data("x".utf8).write(to: u) }
        let conflicts = [a1, a2, b1].map { FileConflict(source: $0, existing: $0, bothDirectories: false) }
        // With the checkbox on: the first "Replace" settles only folderA's two, folderB is still pending (the panel must appear once more)
        var m1 = ConflictDecisionMachine(conflicts)
        m1.decideCurrentFolder(.replace)
        let folderAOnly = m1.decisions.count == 2
            && { if case .replace = m1.decisions[a1] { return true }; return false }()
            && { if case .replace = m1.decisions[a2] { return true }; return false }()
            && m1.decisions[b1] == nil && !m1.isComplete
        record(folderAOnly, "M27 checkbox batch applies to one folder at a time (folderA's 2 settled, folderB still pending)")
        // Panel appearances == number of folders (3 folders → 3 times; here 2 folders → 2 times)
        record(ConflictSheet.uiTestFolderPromptCount(conflicts, batchDecision: .replace) == 2,
               "M27 per-folder batch: panel appearances == folder count (2 folders → 2 times)")
        // Without the checkbox, only the current item is settled
        var m2 = ConflictDecisionMachine(conflicts)
        m2.decideCurrent(.replace)
        record(m2.decisions.count == 1, "M27 without the checkbox only the current item is settled (one by one)")
        // Cancel → nil (contract: abandon everything)
        record(ConflictSheet.uiTestResolve(conflicts, actions: [("cancel", nil)]) == nil,
               "M27 Cancel → resolution returns nil (abandon everything)")
        // Custom-drawn panel: three right-aligned buttons (Cancel/Merge/Replace) + checkbox at bottom left; "Merge" disabled for file conflicts.
        // headless captureView gives a skeleton image (control cells need the window server to render fully; for a real-machine preview see HSPACE_CONFLICT_PREVIEW).
        if let cpanel = ConflictSheet.uiTestPanel(conflicts, host: window) {
            if let cv = cpanel.contentView { captureView(cv, "32-conflict-sheet") }
            let tree = viewTree(cpanel.contentView)
            let btns = tree.compactMap { ($0 as? NSButton)?.title }
            // Since v0.19.22 "Keep Both" was added (user report: only Merge/Cancel, no way to keep both under a new name) → three buttons became four
            let hasFour = btns.contains(L10n.t("conflict.cancel"))
                && btns.contains(L10n.t("conflict.replace")) && btns.contains(L10n.t("conflict.merge"))
                && btns.contains(L10n.t("conflict.keepBoth"))
            let hasCheck = tree.contains { ($0 as? NSButton)?.title == L10n.t("conflict.applyFolder") }
            let mergeBtn = tree.first { ($0 as? NSButton)?.title == L10n.t("conflict.merge") } as? NSButton
            let keepBtn = tree.first { ($0 as? NSButton)?.title == L10n.t("conflict.keepBoth") } as? NSButton
            record(hasFour && hasCheck,
                   "M27 panel has four buttons (Cancel/Merge/Keep Both/Replace) + bottom-left 'apply to this folder' checkbox (custom-drawn, really rendered)")
            // "Keep Both" must also be clickable for **file conflicts** (Merge is folders only; keeping both under a new name works for either)
            record(keepBtn?.isEnabled == true,
                   "M27 file conflict 'Keep Both' available (clickable=\(keepBtn?.isEnabled == true))")
            record(mergeBtn?.isEnabled == false, "M27 file conflict 'Merge' disabled (folders only, honestly unclickable)")
        } else {
            record(false, "M27 panel has four buttons (Cancel/Merge/Keep Both/Replace) + bottom-left 'apply to this folder' checkbox (custom-drawn, really rendered)")
            record(false, "M27 file conflict 'Keep Both' available")
            record(false, "M27 file conflict 'Merge' disabled (folders only, honestly unclickable)")
        }

        window.makeKeyAndOrderFront(nil)   // Main window takes key → the panel's resignKey closes it automatically
        try? await Task.sleep(for: .milliseconds(200))

        // M23 wrap-up: restore the deterministic initial state + clear the sandbox (never pollute user directories/stash/bookmarks)
        listVC.select(urls: [])
        pane.navigate(to: fs.homeDirectoryForCurrentUser)
        pane.setViewMode(.list)
        wc.grid.apply(layout: .single)
        try? await Task.sleep(for: .milliseconds(200))
        try? fs.removeItem(at: sandbox)
        window.makeKeyAndOrderFront(nil)
    }

    private static func runPathCompletionScenario(wc: MainWindowController, window: NSWindow) async {
        // ── I-30: after ⌘L enters path editing, the first key must [take effect at once]: character lands + completion fires on the first key (deferred out of the transaction) ──
        // Root cause: a synchronous complete(nil) inside controlTextDidChange lets the text change transaction swallow the first key's completion popup
        // (no response to the first key, the popup only appears on the second). Fix: defer complete(nil) to the next runloop.
        window.makeKeyAndOrderFront(nil)
        wc.grid.apply(layout: .single)
        try? await Task.sleep(for: .milliseconds(250))
        do {
            let dpane = wc.grid.activePane
            let editor = dpane.uiTestPathEditor
            // Reset focus to the content area (simulates the state before pressing ⌘L), then go through the real beginPathEditing (a clean seed allows exact assertions)
            window.makeFirstResponder(dpane.focusTarget)
            try? await Task.sleep(for: .milliseconds(120))
            dpane.uiTestBeginPathEditing(seed: "")
            try? await Task.sleep(for: .milliseconds(20))
            let seed = editor.stringValue
            let fe = editor.currentEditor() as? NSTextView
            // First key '/': a real field editor keyDown (interpretKeyEvents→insertText→controlTextDidChange→complete)
            if let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    characters: "/", charactersIgnoringModifiers: "/",
                    isARepeat: false, keyCode: 44), let fe {
                fe.keyDown(with: ev)
            }
            try? await Task.sleep(for: .milliseconds(80))   // Wait for the deferred completion to finish
            let afterFirst = editor.stringValue
            // Three real effects: ① character lands at once ② first key computes completion candidates ③ completion fires [outside] the text change transaction (the fix itself)
            record(afterFirst == seed + "/",
                   "I-30 ⌘L first key '/' lands at once (stringValue='\(afterFirst)')")
            record(editor.uiTestLastCompletionCount > 0,
                   "I-30 first key triggers completion candidates (count=\(editor.uiTestLastCompletionCount))")
            record(editor.uiTestCompletionWasDeferred,
                   "I-30 completion fires outside the text change transaction (first key popup not swallowed)")
            dpane.uiTestEndPathEditing()   // Orchestrated wrap-up: leave editing, restore the breadcrumb (so the edit field does not cover screenshots)
            try? await Task.sleep(for: .milliseconds(150))
            editor.stringValue = ""
            window.makeFirstResponder(nil)
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func runPathEditingScenario(wc: MainWindowController, window: NSWindow) async {
        let fs = FileManager.default
        // ── I-53: regression for the three address bar bugs (user report 2026-08-31) ─────────────────
        // bug1: text not selected after ⌘L (old = moveToEndOfLine) → typing/pasting appends instead of replacing
        // bug2: pasting a file path (.apk etc) and pressing Enter only shakes; it should navigate to the parent and select the file
        // bug3: the edit field does not reset on blur: after clearing or clicking elsewhere the address bar stays blank forever
        do {
            let dpane = wc.grid.activePane
            let editor = dpane.uiTestPathEditor
            let i53box = fs.temporaryDirectory
                .appendingPathComponent("hspace-uitest-i53-\(UUID().uuidString)", isDirectory: true)
            let i53file = i53box.appendingPathComponent("app-release.apk")
            try? fs.createDirectory(at: i53box, withIntermediateDirectories: true)
            try? Data("PK".utf8).write(to: i53file)
            defer { try? fs.removeItem(at: i53box) }
            let g53 = assertSandboxed(i53box) && assertSandboxed(i53file)
            record(g53, "Sandbox guard [I-53]: address bar regression fixture inside own temp directory")
            if g53 {
                func pressEnter() {
                    guard let fe = editor.currentEditor() as? NSTextView,
                          let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil,
                                  characters: "\r", charactersIgnoringModifiers: "\r",
                                  isARepeat: false, keyCode: 36) else { return }
                    fe.keyDown(with: ev)
                }
                // bug1: ⌘L selects all
                window.makeFirstResponder(dpane.focusTarget)
                try? await Task.sleep(for: .milliseconds(120))
                dpane.uiTestBeginPathEditing(seed: "/tmp/some/path")
                try? await Task.sleep(for: .milliseconds(30))
                let selRange = (editor.currentEditor() as? NSTextView)?.selectedRange ?? NSRange(location: 0, length: 0)
                let fullLen = editor.stringValue.count
                record(selRange.location == 0 && selRange.length == fullLen && fullLen > 0,
                       "I-53 ⌘L selects all address bar text (selection 0..<\(selRange.length) full length \(fullLen))")
                dpane.uiTestEndPathEditing()
                try? await Task.sleep(for: .milliseconds(100))
                // bug2a: Enter on a folder path → navigate
                window.makeFirstResponder(dpane.focusTarget)
                try? await Task.sleep(for: .milliseconds(120))
                dpane.uiTestBeginPathEditing(seed: i53box.path)
                try? await Task.sleep(for: .milliseconds(30))
                pressEnter()
                try? await Task.sleep(for: .milliseconds(300))
                record(samePath(dpane.uiTestCurrentURL, i53box),
                       "I-53 Enter on folder path → navigates to that folder (got \(dpane.uiTestCurrentURL.lastPathComponent))")
                record(!dpane.uiTestIsPathEditing, "I-53 edit field exits after folder navigation (breadcrumb shown again)")
                // bug2b: Enter on a file path (.apk) → navigate to the parent and select the file
                window.makeFirstResponder(dpane.focusTarget)
                try? await Task.sleep(for: .milliseconds(120))
                dpane.uiTestBeginPathEditing(seed: i53file.path)
                try? await Task.sleep(for: .milliseconds(30))
                pressEnter()
                var revealOK = false
                for _ in 0..<15 {
                    try? await Task.sleep(for: .milliseconds(100))
                    if samePath(dpane.uiTestCurrentURL, i53box),
                       dpane.activeTab.listVC.selectedURLs.contains(where: { samePath($0, i53file) }) {
                        revealOK = true; break
                    }
                }
                record(revealOK,
                       "I-53 Enter on file path (.apk) → navigates to parent and selects the file (dir=\(samePath(dpane.uiTestCurrentURL, i53box)) sel=\(dpane.activeTab.listVC.selectedURLs.count))")
                record(!dpane.uiTestIsPathEditing, "I-53 edit field exits after file reveal (breadcrumb shown again)")
                // bug2c: nonexistent path → no navigation
                let beforeInvalid = dpane.uiTestCurrentURL
                window.makeFirstResponder(dpane.focusTarget)
                try? await Task.sleep(for: .milliseconds(120))
                dpane.uiTestBeginPathEditing(seed: "/definitely/not/exists/\(UUID().uuidString)")
                try? await Task.sleep(for: .milliseconds(30))
                pressEnter()
                try? await Task.sleep(for: .milliseconds(200))
                record(samePath(dpane.uiTestCurrentURL, beforeInvalid),
                       "I-53 Enter on nonexistent path → no navigation (stays in place)")
                // bug3: clearing the address bar and blurring → edit field exits, breadcrumb shows again
                dpane.uiTestBeginPathEditing(seed: "")
                try? await Task.sleep(for: .milliseconds(30))
                dpane.uiTestBlurPathEditor()
                try? await Task.sleep(for: .milliseconds(200))
                record(!dpane.uiTestIsPathEditing,
                       "I-53 clearing address bar then blur → edit field exits, breadcrumb shows current path")
                // bug3b: navigation triggered while editing (emptied) (going up/refresh, with no blur) → the edit field must still exit and the breadcrumb show again.
                // User report: "going up and coming back does not restore it either". This path never blurs, so the blur reset misses it; navigation must force editing closed.
                dpane.navigate(to: i53box)
                try? await Task.sleep(for: .milliseconds(200))
                dpane.uiTestBeginPathEditing(seed: "")   // Enter editing and empty the field
                try? await Task.sleep(for: .milliseconds(30))
                dpane.goUpFolder(nil)                     // Go up while editing (keyboard/menu path, no blur)
                try? await Task.sleep(for: .milliseconds(250))
                record(!dpane.uiTestIsPathEditing && samePath(dpane.uiTestCurrentURL, i53box.deletingLastPathComponent()),
                       "I-53 going up while editing → edit field exits + breadcrumb shows new directory (editing=\(dpane.uiTestIsPathEditing))")
                if dpane.uiTestIsPathEditing { dpane.uiTestEndPathEditing() }
                window.makeFirstResponder(dpane.focusTarget)
                try? await Task.sleep(for: .milliseconds(100))
            }
            // Hygiene: the fixture is about to be deleted, do not leave the pane in a deleted directory to pollute later scenarios
            dpane.navigate(to: fs.homeDirectoryForCurrentUser)
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    private static func runPathParsingScenario(wc: MainWindowController, window: NSWindow) async {
        let fs = FileManager.default
        // ── I-54: address bar path resolution matrix: real clipboard shapes × target types (pure parsing layer, no timing dependency) ────────
        // User report: "sometimes pasting a folder will not navigate, very odd". It is not magic. The old code only did
        // trimmingCharacters(in: .whitespaces) (**that set excludes \n**) + expandingTildeInPath,
        // so five real clipboard shapes (trailing newline / file:// URL / percent encoding / paired quotes / backslash escapes)
        // all fell into the shake branch: the same folder pasted from Finder navigated, pasted from a terminal did not.
        // Assert resolve() directly here: running 26 end-to-end navigations is slow and cannot see the parsing layer; only pure-function assertions pin down the real cause.
        do {
            let dpane = wc.grid.activePane
            let editor = dpane.uiTestPathEditor
            let box = fs.temporaryDirectory
                .appendingPathComponent("hspace-uitest-i54-\(UUID().uuidString)", isDirectory: true)
            let folder = box.appendingPathComponent("My Folder", isDirectory: true)
            let cnFolder = box.appendingPathComponent("Résumé Ünï", isDirectory: true)
            let quoteDir = box.appendingPathComponent("weird'quote", isDirectory: true)
            let slashDir = box.appendingPathComponent("back\\slash", isDirectory: true)
            let pkgDir = box.appendingPathComponent("Test.app", isDirectory: true)
            let apk = folder.appendingPathComponent("app-release.apk")
            let linkDir = box.appendingPathComponent("linkdir")
            let linkFile = box.appendingPathComponent("linkfile")
            for dir in [folder, cnFolder, quoteDir, slashDir, pkgDir] {
                try? fs.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            try? Data("PK".utf8).write(to: apk)
            try? fs.createSymbolicLink(at: linkDir, withDestinationURL: folder)
            try? fs.createSymbolicLink(at: linkFile, withDestinationURL: apk)
            defer { if assertSandboxed(box) { try? fs.removeItem(at: box) } }
            let g54 = assertSandboxed(box) && assertSandboxed(apk)
            record(g54, "Sandbox guard [I-54]: path resolution matrix fixture inside own temp directory")
            if g54 {
                // Relative path cases use the "current browsing directory" as their base, so open the pane on the fixture first
                dpane.navigate(to: box)
                _ = await pollFS { samePath(dpane.uiTestCurrentURL, box) }

                func norm(_ url: URL) -> String {
                    url.resolvingSymlinksInPath().standardizedFileURL.path
                }
                func describe(_ r: PathEditorField.Resolution) -> String {
                    switch r {
                    case .directory(let u): return "DIR:\(norm(u))"
                    case .file(let u):      return "FILE:\(norm(u))"
                    case .unreadable:       return "DENIED"
                    case .notFound:         return "NONE"
                    case .empty:            return "EMPTY"
                    }
                }
                func dirOf(_ u: URL) -> String { "DIR:\(norm(u))" }
                func fileOf(_ u: URL) -> String { "FILE:\(norm(u))" }
                func pct(_ p: String) -> String {
                    p.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? p
                }

                // Dimensions: clipboard shape × target type × special names × negative cases
                let matrix: [(String, String, String)] = [
                    // ① shape × folder
                    ("plain directory",     folder.path,                    dirOf(folder)),
                    ("trailing newline",    folder.path + "\n",             dirOf(folder)),
                    ("trailing CRLF",       folder.path + "\r\n",           dirOf(folder)),
                    ("surrounding spaces",  "  " + folder.path + "  ",      dirOf(folder)),
                    ("trailing slash",      folder.path + "/",              dirOf(folder)),
                    ("file:// unencoded",   "file://" + folder.path,        dirOf(folder)),
                    ("file:// percent",     "file://" + pct(folder.path),   dirOf(folder)),
                    ("double-quoted",       "\"" + folder.path + "\"",      dirOf(folder)),
                    ("single-quoted",       "'" + folder.path + "'",        dirOf(folder)),
                    ("backslash-escaped spaces", folder.path.replacingOccurrences(of: " ", with: "\\ "), dirOf(folder)),
                    ("non-ASCII directory", cnFolder.path,                  dirOf(cnFolder)),
                    ("non-ASCII file:// encoded", "file://" + pct(cnFolder.path), dirOf(cnFolder)),
                    ("relative path",       "My Folder",                    dirOf(folder)),
                    ("./ relative",         "./My Folder",                  dirOf(folder)),
                    ("~ home directory",    "~",                            dirOf(fs.homeDirectoryForCurrentUser)),
                    ("root directory",      "/",                            "DIR:/"),
                    // ② shape × file (the .apk the user named)
                    ("apk file",            apk.path,                       fileOf(apk)),
                    ("apk trailing newline", apk.path + "\n",                fileOf(apk)),
                    ("apk file:// encoded", "file://" + pct(apk.path),      fileOf(apk)),
                    // ③ target type: packages count as files per Finder semantics (select, do not descend); symlinks are followed
                    (".app package treated as a file", pkgDir.path,                    fileOf(pkgDir)),
                    ("symlink→directory",   linkDir.path,                   dirOf(folder)),
                    ("symlink→file",        linkFile.path,                  fileOf(apk)),
                    // ④ names that really contain special characters are not damaged by "smart" parsing (guaranteed by trying the verbatim candidate first)
                    ("name contains a real single quote", quoteDir.path,                  dirOf(quoteDir)),
                    ("name contains a real backslash", slashDir.path,                  dirOf(slashDir)),
                    // ⑤ negative cases
                    ("nonexistent path",    box.appendingPathComponent("nope-\(UUID().uuidString)").path, "NONE"),
                    ("whitespace only",     "   \n  ",                      "EMPTY"),
                ]
                var bad: [String] = []
                for (label, input, expect) in matrix {
                    let got = describe(editor.resolve(input))
                    if got != expect { bad.append("\(label)→\(got)≠\(expect)") }
                }
                record(bad.isEmpty,
                       "I-54 path resolution matrix \(matrix.count - bad.count)/\(matrix.count) passed"
                       + (bad.isEmpty ? "" : "; failed: \(bad.joined(separator: " | "))"))

                // ⑥ end to end: after ⌘L selects all, a "paste" must replace everything, not append.
                // Leave NSPasteboard.general alone: that is the user's real clipboard and a test has no right to pollute it (sandbox hard rule);
                // insertText(insertText (replacing the selection) is the same field editor path ⌘V takes with everything selected.
                window.makeFirstResponder(dpane.focusTarget)
                try? await Task.sleep(for: .milliseconds(120))
                dpane.uiTestBeginPathEditing(seed: "/some/old/path/that/must/be/replaced")
                try? await Task.sleep(for: .milliseconds(30))
                if let fe = editor.currentEditor() as? NSTextView {
                    fe.insertText(apk.path, replacementRange: fe.selectedRange)
                }
                try? await Task.sleep(for: .milliseconds(30))
                record(dpane.uiTestPathEditorText == apk.path,
                       "I-54 ⌘L select-all then paste replaces everything (no append) (got '\(dpane.uiTestPathEditorText)')")

                // ⑦ end to end: Enter on an invalid path → no navigation + inline red hint (no alert)
                let beforeInvalid = dpane.uiTestCurrentURL
                dpane.uiTestBeginPathEditing(seed: "/definitely/not/exists/\(UUID().uuidString)")
                try? await Task.sleep(for: .milliseconds(30))
                if let fe = editor.currentEditor() as? NSTextView,
                   let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil,
                           characters: "\r", charactersIgnoringModifiers: "\r",
                           isARepeat: false, keyCode: 36) {
                    fe.keyDown(with: ev)
                }
                try? await Task.sleep(for: .milliseconds(150))
                record(samePath(dpane.uiTestCurrentURL, beforeInvalid)
                         && dpane.uiTestPathHintVisible
                         && dpane.uiTestIsPathEditing,
                       "I-54 invalid path → no navigation + inline hint + stays in the field for in-place edits (not navigated=\(samePath(dpane.uiTestCurrentURL, beforeInvalid)) hint=\(dpane.uiTestPathHintVisible) '\(dpane.uiTestPathHintText)' still editing=\(dpane.uiTestIsPathEditing))")

                // ⑧ the third path the user named: empty the address bar, then ⌘R refresh: the edit field must exit and the breadcrumb show again.
                // Refresh neither blurs nor navigates, so neither earlier reset path covers it. This uses the **real responder chain** of sendAction
                // (not a direct probe call): the menu item is bound to #selector(FileListViewController.refresh(_:)),
                // and with the address bar focused the chain never reaches those three content VCs, so PaneViewController's same-named method must catch it.
                dpane.uiTestBeginPathEditing(seed: "")
                try? await Task.sleep(for: .milliseconds(30))
                // tryToPerform walks this window's responder chain directly (from firstResponder),
                // avoiding NSApp.sendAction, whose keyWindow dependency may be nil when headless
                let refreshDelivered = window.tryToPerform(
                    #selector(FileListViewController.refresh(_:)), with: nil)
                try? await Task.sleep(for: .milliseconds(200))
                record(refreshDelivered && !dpane.uiTestIsPathEditing,
                       "I-54 emptied address bar then ⌘R refresh → menu action delivered via responder chain and edit field exits (delivered=\(refreshDelivered) still editing=\(dpane.uiTestIsPathEditing))")

                // ⑨ pasting a file "right in the current directory": revealFile navigates to the same directory,
                // and if that path short-circuits as "directory unchanged" the pending selection never lands (0 selected).
                dpane.setViewMode(.list)
                dpane.navigate(to: folder)
                _ = await pollFS { samePath(dpane.uiTestCurrentURL, folder) }
                dpane.activeTab.listVC.tableView.deselectAll(nil)
                try? await Task.sleep(for: .milliseconds(120))
                dpane.uiTestBeginPathEditing(seed: apk.path)
                // The field editor is attached **asynchronously**: the old code slept 30ms before taking currentEditor,
                // and if it was missing the whole keyDown block below was silently skipped: the path was never typed,
                // yet the assertion only said "selected=0", so you could not tell "never typed" from "not selected". The one red in three real-gate runs was this.
                var fieldEditor: NSTextView?
                for _ in 0..<20 {
                    if let fe = editor.currentEditor() as? NSTextView { fieldEditor = fe; break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if let fe = fieldEditor,
                   let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil,
                           characters: "\r", charactersIgnoringModifiers: "\r",
                           isARepeat: false, keyCode: 36) {
                    fe.keyDown(with: ev)
                }
                var sameDirOK = false
                // Polling window 1.5s → 4s: the selection lands only after the directory finishes reading **asynchronously** and the pending reveal runs;
                // when the machine is busy the slow read gave a false red (that editor ready=true, selected=0 case).
                // The window length does not change what is asserted; it just stops treating machine load as a criterion.
                for _ in 0..<40 {
                    try? await Task.sleep(for: .milliseconds(100))
                    if samePath(dpane.uiTestCurrentURL, folder),
                       dpane.activeTab.listVC.selectedURLs.contains(where: { samePath($0, apk) }) {
                        sameDirOK = true; break
                    }
                }
                record(sameDirOK,
                       "I-54 pasting a file from the current directory → selected in place (pending selection not dropped for 'directory unchanged', selected=\(dpane.activeTab.listVC.selectedURLs.count) editor ready=\(fieldEditor != nil))")

                // ⑩ pasting does not pop up completion. This is bug2's second real cause: the popup takes over the event loop and eats the Enter right after it
                // (accepting a candidate instead of navigating). PathCompleter lists directories only: pasting a folder path always has candidates and pops up,
                // pasting an .apk has none, matching the user's "sometimes". Typed characters must still complete as usual (I-30 contract).
                if dpane.uiTestIsPathEditing { dpane.uiTestEndPathEditing() }
                dpane.navigate(to: box)
                _ = await pollFS { samePath(dpane.uiTestCurrentURL, box) }
                window.makeFirstResponder(dpane.focusTarget)
                try? await Task.sleep(for: .milliseconds(120))
                dpane.uiTestBeginPathEditing(seed: "")
                try? await Task.sleep(for: .milliseconds(30))
                let trigBefore = editor.uiTestCompletionTriggerCount
                if let fe = editor.currentEditor() as? NSTextView {
                    fe.insertText(folder.path, replacementRange: fe.selectedRange)   // simulates ⌘V
                }
                try? await Task.sleep(for: .milliseconds(150))
                let afterPaste = editor.uiTestCompletionTriggerCount
                if let fe = editor.currentEditor() as? NSTextView {
                    let end = (editor.stringValue as NSString).length
                    fe.insertText("/", replacementRange: NSRange(location: end, length: 0))  // Type one character by hand
                }
                try? await Task.sleep(for: .milliseconds(180))
                let afterType = editor.uiTestCompletionTriggerCount
                record(afterPaste == trigBefore && afterType > afterPaste,
                       "I-54 paste does not pop up completion (or the popup eats Enter), typing still completes (paste \(trigBefore)→\(afterPaste), keystroke →\(afterType))")

                // ⑪ completion candidates must be "the part that fills charRange". The PathComplete contract returns a full absolute path,
                // AppKit replaces only the last word; returned as is, accepting any candidate builds /a/b//a/b/c/ and the next Enter is sure to shake.
                if let fe = editor.currentEditor() as? NSTextView {
                    let probe = box.path + "/My" as NSString
                    editor.stringValue = probe as String
                    let lastSlash = probe.range(of: "/", options: .backwards).location
                    let partial = NSRange(location: lastSlash + 1, length: probe.length - lastSlash - 1)
                    var idx = -1
                    let cands = editor.control(editor, textView: fe, completions: [],
                                               forPartialWordRange: partial, indexOfSelectedItem: &idx)
                    let segments = !cands.isEmpty && cands.allSatisfy { !$0.hasPrefix("/") }
                    let assembled = probe.substring(to: partial.location) + (cands.first ?? "")
                    let assembledExists = fs.fileExists(atPath: (assembled as NSString).standardizingPath)
                    record(segments && assembledExists,
                           "I-54 completion candidates are the last segment, not the whole absolute path (candidate=\(cands.first ?? "none") assembled=\(((assembled as NSString).lastPathComponent)) exists=\(assembledExists))")
                }

                if dpane.uiTestIsPathEditing { dpane.uiTestEndPathEditing() }
                window.makeFirstResponder(dpane.focusTarget)
            }
            // Hygiene: the fixture is about to be deleted, move the pane back to the home directory first
            dpane.navigate(to: fs.homeDirectoryForCurrentUser)
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    private static func runPathEdgeCasesScenario(wc: MainWindowController, window: NSWindow) async {
        let fs = FileManager.default
        // ── I-55: address bar and reveal edge case fixes (case / hidden files / pending invalidation / Tab completion / drag and drop) ─────
        do {
            let dpane = wc.grid.activePane
            let editor = dpane.uiTestPathEditor
            let box = fs.temporaryDirectory
                .appendingPathComponent("hspace-uitest-i55-\(UUID().uuidString)", isDirectory: true)
            let mixed = box.appendingPathComponent("MixedCase", isDirectory: true)
            let target = mixed.appendingPathComponent("TARGET.txt")
            let hidden = mixed.appendingPathComponent(".secret.txt")
            let tabA = box.appendingPathComponent("CompletionShared-Alpha", isDirectory: true)
            let tabB = box.appendingPathComponent("CompletionShared-Beta", isDirectory: true)
            for dir in [mixed, tabA, tabB] {
                try? fs.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            try? Data("x".utf8).write(to: target)
            try? Data("x".utf8).write(to: hidden)
            defer { if assertSandboxed(box) { try? fs.removeItem(at: box) } }
            let g55 = assertSandboxed(box) && assertSandboxed(target)
            record(g55, "Sandbox guard [I-55]: edge-case fixture inside own temp directory")
            if g55 {
                dpane.setViewMode(.list)
                dpane.navigate(to: box)
                _ = await pollFS { samePath(dpane.uiTestCurrentURL, box) }
                let hiddenWas = dpane.uiTestIncludeHidden

                // ① paths whose case differs from disk still locate. APFS/HFS+ are case-insensitive by default:
                // fileExists passes, but locating used exact string comparison → it jumps to the parent and selects nothing (silent failure).
                let wrongCase = mixed.deletingLastPathComponent()
                    .appendingPathComponent("mixedcase").appendingPathComponent("target.TXT")
                dpane.uiTestBeginPathEditing(seed: wrongCase.path)
                try? await Task.sleep(for: .milliseconds(30))
                pressReturn(in: editor, window: window)
                var caseOK = false
                for _ in 0..<20 {
                    try? await Task.sleep(for: .milliseconds(100))
                    if samePath(dpane.uiTestCurrentURL, mixed),
                       dpane.activeTab.listVC.selectedURLs.contains(where: { samePath($0, target) }) {
                        caseOK = true; break
                    }
                }
                record(caseOK,
                       "I-55 path with case differing from disk still locates and selects (selected=\(dpane.activeTab.listVC.selectedURLs.count))")

                // ② a named hidden file automatically turns on "show hidden"; otherwise it only jumps to the parent without selecting, which looks like "nothing happened"
                dpane.uiTestBeginPathEditing(seed: hidden.path)
                try? await Task.sleep(for: .milliseconds(30))
                pressReturn(in: editor, window: window)
                var hiddenOK = false
                for _ in 0..<20 {
                    try? await Task.sleep(for: .milliseconds(100))
                    if dpane.uiTestIncludeHidden,
                       dpane.activeTab.listVC.selectedURLs.contains(where: { samePath($0, hidden) }) {
                        hiddenOK = true; break
                    }
                }
                record(hiddenOK,
                       "I-55 pasting a hidden file path → auto-shows hidden files and selects (show hidden=\(dpane.uiTestIncludeHidden))")

                // ③ a pending reveal that misses must be cancelled on the spot, not left as a time bomb for a later "ghost jump-select"
                let ghost = mixed.appendingPathComponent("never-exists-\(UUID().uuidString).txt")
                dpane.navigate(to: mixed)
                _ = await pollFS { samePath(dpane.uiTestCurrentURL, mixed) }
                dpane.reveal(ghost)
                _ = await pollFS { !dpane.activeTab.listVC.uiTestHasPendingReveal }
                record(!dpane.activeTab.listVC.uiTestHasPendingReveal,
                       "I-55 target directory loaded but target still missing → pending reveal cancelled (no ghost jump-select)")

                // ④ Tab in the path field completes, it does not move focus (old behaviour: focus moves → blur reset → typed text evaporates)
                dpane.navigate(to: box)
                _ = await pollFS { samePath(dpane.uiTestCurrentURL, box) }
                let stem = box.appendingPathComponent("CompletionShared-A").path
                dpane.uiTestBeginPathEditing(seed: stem)
                try? await Task.sleep(for: .milliseconds(30))
                if let fe = editor.currentEditor() as? NSTextView,
                   let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil,
                           characters: "\t", charactersIgnoringModifiers: "\t",
                           isARepeat: false, keyCode: 48) {
                    fe.keyDown(with: ev)
                }
                try? await Task.sleep(for: .milliseconds(150))
                let tabbed = dpane.uiTestPathEditorText
                record(dpane.uiTestIsPathEditing && samePath(URL(fileURLWithPath: tabbed), tabA),
                       "I-55 Tab completes the sole candidate and stays in the field (got '\((tabbed as NSString).lastPathComponent)' editing=\(dpane.uiTestIsPathEditing))")
                // With multiple candidates, complete to the longest common prefix (pure function, deterministic)
                let lcp = PathEditorField.longestCommonPrefix([tabA.path + "/", tabB.path + "/"])
                record(lcp == box.path + "/CompletionShared-",
                       "I-55 multi-candidate Tab completes to longest common prefix (got '\((lcp as NSString).lastPathComponent)')")

                // ⑤ the address bar accepts file drops (Finder's Go panel and every browser's address bar do).
                // Drives the real drop logic through a private NSPasteboard; never touches the user's real clipboard (sandbox hard rule).
                record(editor.registeredDraggedTypes.contains(.fileURL),
                       "I-55 address bar registered the fileURL drag type")
                let pb = NSPasteboard(name: NSPasteboard.Name("hspace.uitest.i55.\(UUID().uuidString)"))
                pb.clearContents()
                pb.writeObjects([target as NSURL])
                dpane.uiTestBeginPathEditing(seed: "")
                try? await Task.sleep(for: .milliseconds(30))
                let dropped = editor.acceptDrop(from: pb)
                try? await Task.sleep(for: .milliseconds(60))
                record(dropped && samePath(URL(fileURLWithPath: dpane.uiTestPathEditorText), target),
                       "I-55 dragging a file onto the address bar → fills in its path (dropped=\(dropped) got '\((dpane.uiTestPathEditorText as NSString).lastPathComponent)')")
                pb.releaseGlobally()

                // ⑥ when candidates do not line up with "the part before charRange", give no candidates (no popup),
                // instead of handing back a full absolute path for AppKit to replace the last segment; that builds garbage like ~/Users/me/.
                // Typical trigger: typing `~` while the candidate is the expanded /Users/xxx/.
                // Leave editing before probing: while editing, the sync timing between stringValue and the field editor is undefined,
                // which would make this assertion test AppKit's sync behaviour rather than our trimming logic.
                if dpane.uiTestIsPathEditing { dpane.uiTestEndPathEditing() }
                try? await Task.sleep(for: .milliseconds(80))
                do {
                    let probe = NSTextView()   // control(_:textView:...) does not read it, this only satisfies the signature
                    var idx = -1
                    // Control group A (unsafe): head="~" does not line up with the candidate (the expanded absolute path) → must return nothing.
                    // Also check the raw candidate count, proving they "were trimmed" rather than "there were none".
                    editor.stringValue = "~"
                    let unsafeHead = editor.control(editor, textView: probe, completions: [],
                                                    forPartialWordRange: NSRange(location: 1, length: 0),
                                                    indexOfSelectedItem: &idx)
                    let rawForTilde = editor.uiTestLastCompletionCount
                    // Control group B (safe): head is a true prefix of the candidate → returns the last segment, which reassembles the correct path; must not be killed by mistake
                    let stem = (box.path + "/Completion") as NSString
                    let headLen = (box.path + "/" as NSString).length
                    editor.stringValue = stem as String
                    let safe = editor.control(editor, textView: probe, completions: [],
                                              forPartialWordRange: NSRange(location: headLen,
                                                                           length: stem.length - headLen),
                                              indexOfSelectedItem: &idx)
                    editor.stringValue = ""
                    let assembled = box.path + "/" + (safe.first ?? "")
                    let assembledOK = !safe.isEmpty && fs.fileExists(atPath: assembled)
                    record(unsafeHead.isEmpty && rawForTilde > 0 && assembledOK,
                           "I-55 completion candidates with mismatched head all trimmed (raw \(rawForTilde)→0), matching head returns last segment (\(safe.count) items, assembled \((assembled as NSString).lastPathComponent) exists=\(assembledOK))")
                }

                // ⑦ the shake animation must use layer.position.x as its base. For AppKit layer-backed views anchorPoint=(0,0),
                // so layer.position is the frame origin, not the center; basing on frame.midX makes the address bar first "teleport"
                // half its width and then bounce back, which looks like the whole control glitching rather than one shake.
                dpane.uiTestBeginPathEditing(seed: "/definitely/not/exists/\(UUID().uuidString)")
                try? await Task.sleep(for: .milliseconds(30))
                pressReturn(in: editor, window: window)
                _ = await pollFS { !editor.uiTestShakeValues.isEmpty }
                let shakeVals = editor.uiTestShakeValues
                let baseX = editor.layer?.position.x ?? -999
                record(!shakeVals.isEmpty
                         && abs((shakeVals.first ?? -999) - baseX) < 0.5
                         && abs(baseX - editor.frame.midX) > 1,
                       "I-55 shake is based on layer.position.x (first frame \(Int(shakeVals.first ?? -1)) ≈ position.x \(Int(baseX)), compare frame.midX=\(Int(editor.frame.midX)))")

                // ⑧ pasting a file path must also select in column mode. The column chain rebuilds asynchronously; if a column still held stale content from the previous
                // directory, the old code cleared the pending selection on the spot → once the right content loaded, it never selected (silent loss).
                if dpane.uiTestIsPathEditing { dpane.uiTestEndPathEditing() }
                dpane.setViewMode(.columns)
                try? await Task.sleep(for: .milliseconds(300))
                dpane.navigate(to: box)
                _ = await pollFS { samePath(dpane.uiTestCurrentURL, box) }
                dpane.uiTestBeginPathEditing(seed: target.path)
                try? await Task.sleep(for: .milliseconds(30))
                pressReturn(in: editor, window: window)
                var colOK = false
                for _ in 0..<25 {
                    try? await Task.sleep(for: .milliseconds(100))
                    if let sel = dpane.activeTab.columnVC?.selectedURLs,
                       sel.contains(where: { samePath($0, target) }) { colOK = true; break }
                }
                record(colOK,
                       "I-55 pasting a file path in column mode also selects (stale column does not swallow pending selection, selected=\(dpane.activeTab.columnVC?.selectedURLs.count ?? -1))")
                dpane.setViewMode(.list)
                try? await Task.sleep(for: .milliseconds(200))

                // ⑨ switching pane layout while editing the address bar: rebuilding the view hierarchy knocks a firstResponder on a removed view
                // back to the window itself (not any NSView) → the keyboard goes dead until the user clicks something.
                let layoutWas = wc.grid.layout
                dpane.uiTestBeginPathEditing(seed: "/tmp")
                try? await Task.sleep(for: .milliseconds(50))
                wc.grid.apply(layout: .dualH)
                try? await Task.sleep(for: .milliseconds(350))
                let frAfter = window.firstResponder
                record(frAfter is NSView,
                       "I-56 layout switch while editing the address bar: focus stays on a control instead of falling back to the window (keyboard alive, got \(frAfter.map { String(describing: type(of: $0)) } ?? "nil"))")
                wc.grid.apply(layout: layoutWas)
                try? await Task.sleep(for: .milliseconds(300))

                // ⑩ switching view mode during a disk read: the pending reveal target must move to the new view. Within one runloop
                // navigate + reveal + view switch: the async read cannot be back yet, so pending can only sit on the old view,
                // and without moving it is lost forever (and left in the old view as a time bomb for a later "ghost jump-select").
                dpane.setViewMode(.list)
                try? await Task.sleep(for: .milliseconds(200))
                dpane.navigate(to: box)
                _ = await pollFS { samePath(dpane.uiTestCurrentURL, box) }
                dpane.navigate(to: mixed)
                dpane.reveal(target)
                // Assert the "transfer" itself directly: the final selection alone cannot detect it, since selection can still land via
                // restoreSelection or the shared model's multicast, turning the assertion into a toothless false green.
                let listHadPending = dpane.activeTab.listVC.uiTestHasPendingReveal
                dpane.setViewMode(.icons)   // Synchronous, no await in between, so the disk read cannot be back yet
                let listStillPending = dpane.activeTab.listVC.uiTestHasPendingReveal
                let iconNowPending = dpane.activeTab.iconVC?.uiTestHasPendingReveal ?? false
                var carriedOK = false
                for _ in 0..<30 {
                    try? await Task.sleep(for: .milliseconds(100))
                    if let sel = dpane.activeTab.iconVC?.selectedURLs,
                       sel.contains(where: { samePath($0, target) }) { carriedOK = true; break }
                }
                record(listHadPending && !listStillPending && iconNowPending && carriedOK,
                       "I-56 view mode switch during disk read moves the pending reveal target to the new view (old view \(listHadPending)→\(listStillPending), new view holds it=\(iconNowPending), final selection=\(carriedOK))")
                dpane.setViewMode(.list)
                try? await Task.sleep(for: .milliseconds(200))

                if dpane.uiTestIsPathEditing { dpane.uiTestEndPathEditing() }
                // Restore: this scenario turned on "show hidden" to locate the hidden file; do not leak that state to later scenarios
                if dpane.uiTestIncludeHidden != hiddenWas { dpane.uiTestSetIncludeHidden(hiddenWas) }
                window.makeFirstResponder(dpane.focusTarget)
            }
            dpane.navigate(to: fs.homeDirectoryForCurrentUser)
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    private static func runPathFocusScenario(wc: MainWindowController, window: NSWindow) async {
        let fs = FileManager.default
        // ── I-57: reset gap when the window loses key + stronger bug3 assertions ─────────────────────────
        // Measured with a standalone AppKit probe: on window resignKey AppKit **does not send** controlTextDidEndEditing
        //(the field editor remains, isHidden is still false), so the blur reset path is completely blind to it.
        do {
            let dpane = wc.grid.activePane
            // (a) an empty address bar must collapse by itself: ⌘L → ⌫ to empty → open settings/⌘F/⌘Tab, and it must not still be a blank field on return
            dpane.uiTestBeginPathEditing(seed: "")
            try? await Task.sleep(for: .milliseconds(60))
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
            try? await Task.sleep(for: .milliseconds(180))
            let emptyCollapsed = !dpane.uiTestIsPathEditing
            // (b) anything typed is always kept: ⌘L → switch to Finder to copy a path → switch back and ⌘V is bug2's top use case.
            //     An unconditional reset would close the field and return focus to the file list, so that ⌘V hits the list's pasteItems
            //     and becomes "paste files into the current directory": a pure browsing action escalated into a disk write.
            dpane.uiTestBeginPathEditing(seed: "/tmp/keep-me-while-away")
            try? await Task.sleep(for: .milliseconds(60))
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
            try? await Task.sleep(for: .milliseconds(180))
            let textKept = dpane.uiTestIsPathEditing
                && dpane.uiTestPathEditorText == "/tmp/keep-me-while-away"
            record(emptyCollapsed && textKept,
                   "I-57 window loses key: empty address bar collapses, any content is kept (collapsed=\(emptyCollapsed) kept=\(textKept) '\(dpane.uiTestPathEditorText)')")
            dpane.uiTestEndPathEditing()
            try? await Task.sleep(for: .milliseconds(150))

            // (c) "breadcrumb shown again" must verify content + the field editor really released. The old assertion checked only !isHidden:
            //    delete the breadcrumb.isHidden = false line and it stayed green, a false green.
            record(dpane.uiTestBreadcrumbVisible
                     && samePath(dpane.uiTestBreadcrumbURL, dpane.uiTestCurrentURL)
                     && !dpane.uiTestPathEditorHasFocus,
                   "I-57 after editing, breadcrumb really shows the current directory and field editor is released (breadcrumb=\(dpane.uiTestBreadcrumbURL.lastPathComponent) current=\(dpane.uiTestCurrentURL.lastPathComponent) still focused=\(dpane.uiTestPathEditorHasFocus))")

            // (d) the **real entry** of ⌘L: the uiTestBeginPathEditing that I-53 calls is a copy of beginPathEditing;
            //     the menu binding → responder chain → editPath path never ran once. This goes through the real chain.
            window.makeFirstResponder(dpane.focusTarget)
            try? await Task.sleep(for: .milliseconds(150))
            let editPathDelivered = window.tryToPerform(
                #selector(PaneViewController.editPath(_:)), with: nil)
            try? await Task.sleep(for: .milliseconds(180))
            let selRange = (dpane.uiTestPathEditor.currentEditor() as? NSTextView)?.selectedRange
                ?? NSRange(location: 0, length: 0)
            let fullLen = (dpane.uiTestPathEditorText as NSString).length
            record(editPathDelivered && dpane.uiTestIsPathEditing
                     && selRange.location == 0 && selRange.length == fullLen && fullLen > 0,
                   "I-57 ⌘L delivered via the real responder chain and selects all (delivered=\(editPathDelivered) selection 0..<\(selRange.length)/full length \(fullLen))")
            if dpane.uiTestIsPathEditing { dpane.uiTestEndPathEditing() }
            window.makeFirstResponder(dpane.focusTarget)
            try? await Task.sleep(for: .milliseconds(120))

            // (e) different spellings of one directory must not stack up in the back history: compared verbatim, `/a/b`, `/a/b/`
            // and forms with `..` are all unequal, so one directory enters history repeatedly and ⌘[ seems to "stay in place".
            // Pasting a path with a trailing slash into the address bar is the easiest way to hit this.
            let home = fs.homeDirectoryForCurrentUser
            dpane.navigate(to: home)
            _ = await pollFS { samePath(dpane.uiTestCurrentURL, home) }
            let backBefore = dpane.backHistory.count
            dpane.navigate(to: URL(fileURLWithPath: home.path + "/"))
            dpane.navigate(to: URL(fileURLWithPath: home.path + "/Downloads/.."))
            try? await Task.sleep(for: .milliseconds(200))
            record(dpane.backHistory.count == backBefore
                     && samePath(dpane.uiTestCurrentURL, home),
                   "I-57 different spellings of one directory do not stack in back history (back history \(backBefore)→\(dpane.backHistory.count))")
        }
    }

    private static func runSortIndicatorScenario(wc: MainWindowController, window: NSWindow) async {
        // ── I-58: the sort indicator must keep up with model.sort (user report: "sort state lost") ───────────────
        // The truth: data flow was one-way, only "click header → sortDescriptorsDidChange → model.sort",
        // with no reverse. After session restore / a new pane / a column rebuild, content was sorted right by model.sort but the header arrow stayed on
        // the default "Name", so the user saw "the sort was lost". I-50 asserted only the disk write, driven through that existing header-click path,
        // and structurally could not see the restore direction: a green light coexisting with the user's bug.
        do {
            let dpane = wc.grid.activePane
            dpane.setViewMode(.list)
            try? await Task.sleep(for: .milliseconds(200))
            // Change the model directly (simulates session restore: restore writes model.sort this way, not through the header)
            dpane.uiTestSetSort(key: "dateModified", ascending: false)
            try? await Task.sleep(for: .milliseconds(400))
            let ind = dpane.uiTestSortIndicator
            let mdl = dpane.uiTestModelSort
            record(mdl.key == "dateModified" && mdl.ascending == false
                     && ind?.key == "dateModified" && ind?.ascending == false,
                   "I-58 model sort change syncs the column header indicator (model=\(mdl.key)/\(mdl.ascending) indicator=\(ind?.key ?? "none")/\(ind.map { String($0.ascending) } ?? "-"))")

            // After rebuilding optional columns (removed and added back) the indicator must not be lost
            NotificationCenter.default.post(name: .hspaceColumnsChanged, object: nil)
            try? await Task.sleep(for: .milliseconds(400))
            let ind2 = dpane.uiTestSortIndicator
            record(ind2?.key == "dateModified" && ind2?.ascending == false,
                   "I-58 indicator survives column rebuild (got \(ind2?.key ?? "none")/\(ind2.map { String($0.ascending) } ?? "-"))")

            // Wrap up: restore ascending by name, do not leak the sort to later scenarios
            dpane.uiTestSetSort(key: "name", ascending: true)
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private static func runDirectoryCopyPathScenario(wc: MainWindowController, window: NSWindow) async {
        let fs = FileManager.default
        // ── I-59: copy path from the blank area of a folder (user report: "can only copy files, not the current folder") ──────
        // Two causes: ① copyPath passes only selectedURLs, an empty array with no selection, and coordinator.copyPaths'
        // guard !urls.isEmpty swallows it; ② validateMenuItem puts copyPath in the hasSelection group,
        // so the menu item is disabled with no selection and ⌘⇧C on blank area never dispatches. All three views share this, so all three are checked.
        do {
            let dpane = wc.grid.activePane
            let box = fs.temporaryDirectory
                .appendingPathComponent("hspace-uitest-i59-\(UUID().uuidString)", isDirectory: true)
            try? fs.createDirectory(at: box, withIntermediateDirectories: true)
            try? Data("x".utf8).write(to: box.appendingPathComponent("a.txt"))
            defer { if assertSandboxed(box) { try? fs.removeItem(at: box) } }
            let g59 = assertSandboxed(box)
            record(g59, "Sandbox guard [I-59]: copy-path fixture inside own temp directory")
            if g59 {
                // Use a **private** pasteboard: it leaves the user's real clipboard alone and cannot be rewritten midway by
                // another process, causing a false failure (hit once in practice: the assertion read text copied elsewhere)
                let pb = NSPasteboard(name: NSPasteboard.Name("hspace.uitest.i59.\(UUID().uuidString)"))
                var results: [String] = []
                for (mode, name) in [(PaneViewMode.list, "list"),
                                     (PaneViewMode.icons, "icons"),
                                     (PaneViewMode.columns, "columns")] {
                    dpane.setViewMode(mode)
                    try? await Task.sleep(for: .milliseconds(250))
                    dpane.navigate(to: box)
                    _ = await pollFS { samePath(dpane.uiTestCurrentURL, box) }
                    // Columns load asynchronously one at a time: a fixed sleep sometimes gets an old column not yet in place
                    //(measured 1 in 5 runs got the previous directory), so poll until this view's "current directory" really lines up
                    _ = await pollFS(40) { samePath(dpane.uiTestViewCurrentDirectory, box) }
                    dpane.uiTestClearSelection()              // simulates clicking blank area
                    try? await Task.sleep(for: .milliseconds(150))
                    pb.clearContents()
                    pb.setString("SENTINEL", forType: .string)
                    dpane.uiTestCopyPath(to: pb)              // through each view's real copyPath logic
                    try? await Task.sleep(for: .milliseconds(250))
                    let got = pb.string(forType: .string) ?? ""
                    let ok = !got.isEmpty && got != "SENTINEL"
                        && samePath(URL(fileURLWithPath: got), box)
                    results.append("\(name)=\(ok ? "✓" : "✗(\((got as NSString).lastPathComponent))")")
                }
                record(results.allSatisfy { $0.contains("✓") },
                       "I-59 empty selection copy path falls back to the current directory (three views \(results.joined(separator: " ")))")
                pb.releaseGlobally()
                dpane.setViewMode(.list)
                try? await Task.sleep(for: .milliseconds(200))
            }
            dpane.navigate(to: fs.homeDirectoryForCurrentUser)
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private static func runExternalOpenQueueScenario(wc: MainWindowController, window: NSWindow, delegate: AppDelegate) async {
        let fs = FileManager.default
        // ── I-60: an external open during cold start must not open an extra window (user report: "browser open in Finder still creates a new window") ──
        // restoreSessionOrDefault is async (awaits reading session.json), while application(_:open:)
        // arrives early and synchronously from LaunchServices: when HSpace is launched by "Show in Finder" while not running, the request arrives at the **zero-window moment**
        // → activeMainWindowController() is nil → falls into the new-window branch; then session restore opens its own window.
        // Measured on a real machine: 2 windows before the fix, 1 after. This asserts the queueing mechanism itself (no real cold start, to leave the user's session alone).
        do {
            let box = fs.temporaryDirectory
                .appendingPathComponent("hspace-uitest-i60-\(UUID().uuidString)", isDirectory: true)
            try? fs.createDirectory(at: box, withIntermediateDirectories: true)
            defer { if assertSandboxed(box) { try? fs.removeItem(at: box) } }
            let g60 = assertSandboxed(box)
            record(g60, "Sandbox guard [I-60]: external open queue fixture inside own temp directory")
            if g60 {
                func mainWins() -> Int {
                    NSApp.windows.filter { $0.windowController is MainWindowController && $0.isVisible }.count
                }
                let before = mainWins()
                let queuedBefore = delegate.uiTestPendingExternalOpenCount
                // ① delivered while the session is not ready: must only queue, opening no window at all
                delegate.uiTestDeliverExternalOpenWhileNotReady(box)
                try? await Task.sleep(for: .milliseconds(300))
                let queuedAfter = delegate.uiTestPendingExternalOpenCount
                let winsAfterQueue = mainWins()
                record(queuedAfter == queuedBefore + 1 && winsAfterQueue == before,
                       "I-60 external open before session ready only queues, opens no window (queue \(queuedBefore)→\(queuedAfter), windows \(before)→\(winsAfterQueue))")
                // ② landing after the flush: queue emptied, and still no new window (takes the "new workspace tab in the existing window" branch)
                let wsBefore = wc.workspaceCount
                delegate.uiTestFlushPendingExternalOpens()
                _ = await pollFS { delegate.uiTestPendingExternalOpenCount == 0 }
                try? await Task.sleep(for: .milliseconds(400))
                let winsAfterFlush = mainWins()
                let wsAfter = wc.workspaceCount
                record(delegate.uiTestPendingExternalOpenCount == 0
                         && winsAfterFlush == before && wsAfter == wsBefore + 1,
                       "I-60 after flush lands in a new workspace tab of the existing window (windows \(before)→\(winsAfterFlush), workspaces \(wsBefore)→\(wsAfter))")
                // Wrap up: close the workspace this scenario opened
                while wc.workspaceCount > wsBefore { wc.closeActiveWorkspace(nil) }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private static func runTrashSelectionScenario(wc: MainWindowController, window: NSWindow) async {
        let fs = FileManager.default
        let pane = wc.grid.activePane
        // ── Scenario I-32: selection clears after multi-select delete (move to Trash), checked in all three views ─────────────────
        // User bug report: after multi-select delete the highlight "followed" to the new row that moved up (selection should clear).
        // Hard rule: touch only self-created hspace-uitest-i32-* fixtures (assertSandboxed guard); really move to Trash through coordinator;
        //       at the end state, assert the view-layer selection is truly empty (raw selectedRowIndexes empty) and the status bar has no "selected" pill.
        let i32TrashDir = fs.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        for (i32Mode, i32Name) in [(PaneViewMode.list, "list"), (.icons, "icons"), (.columns, "columns")] {
            let token = String(UUID().uuidString.prefix(8))
            let i32box = fs.temporaryDirectory
                .appendingPathComponent("hspace-uitest-i32-\(token)", isDirectory: true)
            let fileNames = ["hspace-uitest-i32-\(token)-a.txt",
                             "hspace-uitest-i32-\(token)-b.txt",
                             "hspace-uitest-i32-\(token)-c.txt"]
            try? fs.createDirectory(at: i32box, withIntermediateDirectories: true)
            for n in fileNames { try? Data("x".utf8).write(to: i32box.appendingPathComponent(n)) }

            pane.setViewMode(i32Mode)
            try? await Task.sleep(for: .milliseconds(250))
            pane.navigate(to: i32box)
            // Focused view's visible item count (columns read the focused column, list/icons read the shared model)
            @MainActor func i32VisibleCount() -> Int {
                i32Mode == .columns ? (pane.activeTab.columnVC?.statusCounts.items ?? 0)
                                    : pane.activeTab.model.items.count
            }
            _ = await pollFS { i32VisibleCount() >= 3 }
            try? await Task.sleep(for: .milliseconds(200))

            // Select the first two items through each view's real selection chain; victims come from "loaded real item URLs" (avoids symlink path mismatches)
            let victims: [URL]
            switch i32Mode {
            case .list, .icons:
                victims = Array(pane.activeTab.model.items.prefix(2)).map(\.url)
            case .columns:
                victims = Array((pane.activeTab.columnVC?.uiTestFocusedColumnItemURLs ?? []).prefix(2))
            }
            switch i32Mode {
            case .list:    pane.activeTab.listVC.select(urls: victims)
            case .icons:   pane.activeTab.iconVC?.select(urls: victims)
            case .columns: pane.activeTab.columnVC?.uiTestSelectInFocusedColumn(victims)
            }
            try? await Task.sleep(for: .milliseconds(200))
            let selBefore = pane.currentSelectionCount

            let gI32 = victims.allSatisfy { assertSandboxed($0) }
            record(gI32, "Sandbox guard [\(i32Name)]: I-32 move-to-Trash targets inside own fixture")
            if gI32 { wc.coordinator.moveToTrash(victims) }   // Real coordinator → kernel → trash
            // Wait for the end state: the focused view has 1 item left (reloadLists fires after the kernel end state)
            let settled = gI32 ? (await pollFS { i32VisibleCount() == 1 }) : false
            try? await Task.sleep(for: .milliseconds(150))

            // Assert: raw view-layer selection count=0 ("drift" to a new row excluded) and no "selected" pill in the status bar
            let rawSel: Int
            switch i32Mode {
            case .list:    rawSel = pane.activeTab.listVC.tableView.selectedRowIndexes.count
            case .icons:   rawSel = pane.activeTab.iconVC?.uiTestRawSelectionCount ?? -1
            case .columns: rawSel = pane.activeTab.columnVC?.uiTestFocusedRawSelectionCount ?? -1
            }
            let pillVisible = pane.uiTestRefreshAndSelectionPillVisible()
            record(selBefore == 2 && settled && rawSel == 0 && !pillVisible,
                   "Selection clears after multi-select delete [\(i32Name)] (selected before \(selBefore), 1 left at end=\(settled), selected after \(rawSel), pill=\(pillVisible))")

            // Cleanup: fixture directory + uniquely named test items that landed in the Trash (token is unique, safe)
            switch i32Mode {
            case .list:    pane.activeTab.listVC.select(urls: [])
            case .icons:   pane.activeTab.iconVC?.select(urls: [])
            case .columns: pane.activeTab.columnVC?.select(urls: [])
            }
            pane.navigate(to: fs.homeDirectoryForCurrentUser)
            try? await Task.sleep(for: .milliseconds(150))
            try? fs.removeItem(at: i32box)
            if let entries = try? fs.contentsOfDirectory(atPath: i32TrashDir.path) {
                for e in entries where e.hasPrefix("hspace-uitest-i32-\(token)") {
                    try? fs.removeItem(at: i32TrashDir.appendingPathComponent(e))
                }
            }
        }
        pane.setViewMode(.list)
        pane.navigate(to: fs.homeDirectoryForCurrentUser)
        try? await Task.sleep(for: .milliseconds(150))
        window.makeKeyAndOrderFront(nil)
    }

    private static func runBreadcrumbFitScenario(wc: MainWindowController, window: NSWindow) async {
        let fs = FileManager.default
        let pane = wc.grid.activePane
        // ── Scenario I-37: breadcrumb address bar fits its width: deep paths/long names do not overflow + middle collapse keeps all levels reachable ──
        // User's words: "show every level in the address bar whenever possible". The sandbox builds an 8-level chain of 40-character names;
        // after navigating to the deepest level, assert: ① content really does not overflow ② the '…' collapse segment exists and its menu item count == collapsed levels
        // ③ programmatically firing a collapse menu item → pane path really jumps to that level ④ visible last segment toolTip == full name.
        // Hard rule: touch only self-created hspace-uitest-i37-* fixtures (assertSandboxed guard); clean up afterwards.
        wc.grid.apply(layout: .single)
        pane.setViewMode(.list)
        try? await Task.sleep(for: .milliseconds(200))
        window.contentView?.layoutSubtreeIfNeeded()
        do {
            let token = String(UUID().uuidString.prefix(8))
            // Each level's name is exactly 40 characters (unique identifiable prefix + padding with "Ü")
            @MainActor func longName(_ i: Int) -> String {
                let prefix = "hspace-uitest-i37-\(token)-L\(i)-"
                return prefix + String(repeating: "Ü", count: max(0, 40 - prefix.count))
            }
            let base = fs.temporaryDirectory
                .appendingPathComponent("hspace-uitest-i37-\(token)", isDirectory: true)
            var deep = base
            for i in 1...8 { deep = deep.appendingPathComponent(longName(i), isDirectory: true) }
            try? fs.createDirectory(at: deep, withIntermediateDirectories: true)

            let gI37 = assertSandboxed(deep)
            record(gI37, "Sandbox guard: I-37 deep chain inside own fixture")

            let bc = pane.uiTestBreadcrumb
            pane.navigate(to: deep)
            try? await Task.sleep(for: .milliseconds(400))
            window.contentView?.layoutSubtreeIfNeeded()
            bc.layoutSubtreeIfNeeded()

            // ① no overflow: content right edge ≤ container width + 2 (really measures layout, not "did not crash")
            let containerW = bc.bounds.width
            let contentR = bc.uiTestContentRight
            record(contentR <= containerW + 2,
                   "I-37 breadcrumb does not overflow (content right edge \(Int(contentR)) ≤ container \(Int(containerW))+2)")
            capture(window, "30-breadcrumb-deep")

            // ② the '…' collapse segment exists and menu item count == collapsed levels
            let hasEllipsis = bc.uiTestHasEllipsis
            let collapsed = bc.uiTestCollapsedURLs
            let menu = bc.uiTestEllipsisMenu()
            let menuCount = menu?.items.count ?? -1
            record(hasEllipsis && menu != nil && collapsed.count > 0 && menuCount == collapsed.count,
                   "I-37 '…' collapse segment exists and menu item count == collapsed levels (collapsed \(collapsed.count), menu \(menuCount))")

            // ③ programmatically fire the middle collapse menu item → pane path really jumps to that level
            if let menu, !menu.items.isEmpty,
               let mid = Optional(menu.items[menu.items.count / 2]),
               let targetURL = mid.representedObject as? URL {
                _ = mid.target?.perform(mid.action, with: mid)
                try? await Task.sleep(for: .milliseconds(350))
                record(samePath(pane.activeTab.browser.current, targetURL),
                       "I-37 clicking a collapse menu item → pane really jumps to that level (\(targetURL.lastPathComponent.prefix(16))…)")
            } else {
                record(false, "I-37 clicking a collapse menu item → pane really jumps to that level")
            }

            // Back to the deepest level, to check ④ and the narrow pane state
            pane.navigate(to: deep)
            try? await Task.sleep(for: .milliseconds(350))
            window.contentView?.layoutSubtreeIfNeeded()
            bc.layoutSubtreeIfNeeded()

            // ④ visible last segment toolTip == full name (the 40-character full name)
            let tip = bc.uiTestLastSegmentToolTip
            let full = bc.uiTestLastSegmentFullName
            record(tip != nil && full != nil && tip == full && (full?.count ?? 0) == 40,
                   "I-37 visible last segment toolTip == full name (length \(full?.count ?? -1))")

            // Narrow pane state: shrink the window, take another shot; after level-by-level collapsing it still really does not overflow
            let savedFrame = window.frame
            window.setFrame(NSRect(x: savedFrame.origin.x, y: savedFrame.origin.y,
                                   width: 520, height: savedFrame.height), display: true)
            try? await Task.sleep(for: .milliseconds(400))
            window.contentView?.layoutSubtreeIfNeeded()
            bc.layoutSubtreeIfNeeded()
            let narrowW = bc.bounds.width
            let narrowR = bc.uiTestContentRight
            record(narrowR <= narrowW + 2,
                   "I-37 narrow pane still does not overflow (content right edge \(Int(narrowR)) ≤ container \(Int(narrowW))+2)")
            capture(window, "30b-breadcrumb-narrow")
            window.setFrame(savedFrame, display: true)
            try? await Task.sleep(for: .milliseconds(250))

            // Clean up the fixture (token is unique, safe)
            pane.navigate(to: fs.homeDirectoryForCurrentUser)
            try? await Task.sleep(for: .milliseconds(200))
            try? fs.removeItem(at: base)
        }
    }

    /// Scenario I-65: five user reports: ⌘V pastes clipboard content as a new file, clicking a selected item renames it,
    /// the list bottom always keeps right-clickable blank space, new file has a shortcut. All check the "real effect".
    /// Scenario I-67: the selection must not vanish after ⌘C / ⌘X (user report).
    /// Root cause: `redraw()` used `tableView.reloadData()`, which clears the selection, while in "redraw" semantics
    /// the rows did not change, so neither should the selection. Same for cut: it only grays rows and deletes nothing.
    private static func runSelectionSurvivesClipboardScenario(wc: MainWindowController,
                                                              window: NSWindow) async {
        let fs = FileManager.default
        let pane = wc.grid.activePane
        let tok = String(UUID().uuidString.prefix(8))
        let box = fs.temporaryDirectory
            .appendingPathComponent("hspace-uitest-i67-\(tok)", isDirectory: true)
        try? fs.createDirectory(at: box, withIntermediateDirectories: true)
        for i in 1...4 { try? Data("x".utf8).write(to: box.appendingPathComponent("f\(i).txt")) }
        record(assertSandboxed(box), "Sandbox guard [I-67]: clipboard selection fixture inside own temp directory")
        guard assertSandboxed(box) else { return }
        defer { try? fs.removeItem(at: box) }

        pane.uiTestEndPathEditing()
        pane.navigate(to: box)
        _ = await pollFS { pane.activeTab.model.items.count == 4 }
        window.contentView?.layoutSubtreeIfNeeded()

        let listVC = pane.activeTab.listVC
        // Select two items (multi-select exposes the problem better: reloadData clears them together)
        let victims = Array(pane.activeTab.model.items.prefix(2)).map(\.url)
        listVC.uiTestSelect(urls: victims)
        try? await Task.sleep(for: .milliseconds(150))
        let before = Set(listVC.selectedURLs.map(\.lastPathComponent))
        let rawBefore = listVC.uiTestRawSelectionCount

        // ⌘C goes through the **real** coordinator.copy (which calls redrawLists internally)
        wc.coordinator.copy(victims)
        try? await Task.sleep(for: .milliseconds(300))
        let afterCopy = Set(listVC.selectedURLs.map(\.lastPathComponent))
        let rawAfterCopy = listVC.uiTestRawSelectionCount

        // ⌘X must not clear the selection either (cut only grays, nothing is deleted)
        wc.coordinator.cut(victims)
        try? await Task.sleep(for: .milliseconds(300))
        let afterCut = Set(listVC.selectedURLs.map(\.lastPathComponent))
        let rawAfterCut = listVC.uiTestRawSelectionCount

        record(before.count == 2 && rawBefore == 2
               && afterCopy == before && rawAfterCopy == 2
               && afterCut == before && rawAfterCut == 2,
               "I-67 selection survives copy/cut (selected \(before.count)→after copy \(afterCopy.count)→after cut \(afterCut.count); view layer \(rawBefore)→\(rawAfterCopy)→\(rawAfterCut))")

        pane.navigate(to: fs.homeDirectoryForCurrentUser)
        try? await Task.sleep(for: .milliseconds(200))
    }

    /// Scenario I-68: the sidebar should navigate on one click (user report: clicking "Downloads" did nothing until clicking something else and back).
    /// Two independent defects: ① the highlight did not follow the pane at all, it just pointed at "what was last clicked";
    /// ② there was no click-driven path: clicking the selected row leaves selection unchanged → selectionDidChange does not fire.
    private static func runSidebarNavigationScenario(wc: MainWindowController,
                                                     window: NSWindow) async {
        let fs = FileManager.default
        let pane = wc.grid.activePane
        let sidebar = wc.sidebar
        let home = fs.homeDirectoryForCurrentUser
        let downloads = home.appendingPathComponent("Downloads")
        let docs = home.appendingPathComponent("Documents")

        let rowDownloads = sidebar.uiTestRow(for: downloads)
        let rowDocs = sidebar.uiTestRow(for: docs)
        guard rowDownloads >= 0, rowDocs >= 0 else {
            record(false, "I-68 sidebar navigates on one click (Downloads/Documents rows not found in the sidebar, cannot verify)")
            return
        }

        // ① click "Downloads" first, then change directory by a **non-sidebar** route (simulates walking away by breadcrumb/double-click)
        pane.uiTestEndPathEditing()
        sidebar.uiTestClickRow(rowDownloads)
        let arrived = await pollFS { pane.uiTestCurrentURL.standardizedFileURL.path
                                      == downloads.standardizedFileURL.path }
        pane.navigate(to: home)
        _ = await pollFS { pane.uiTestCurrentURL.standardizedFileURL.path
                            == home.standardizedFileURL.path }
        try? await Task.sleep(for: .milliseconds(200))

        // ② the highlight must follow the pane: we are in home now (not a bookmark item) → "Downloads" must not stay highlighted and lie
        let staleHighlight = sidebar.uiTestSelectedURL?.standardizedFileURL.path
        record(arrived && staleHighlight != downloads.standardizedFileURL.path,
               "I-68 after a directory change the sidebar highlight no longer points at the old location (reached Downloads=\(arrived) current highlight=\(staleHighlight ?? "none"))")

        // ③ click "Documents" → enter Documents; then **click the same row again** (now already selected) → must still navigate.
        //   This step is the subject of the user report: in the old version the second click did nothing.
        sidebar.uiTestClickRow(rowDocs)
        let toDocs = await pollFS { pane.uiTestCurrentURL.standardizedFileURL.path
                                     == docs.standardizedFileURL.path }
        pane.navigate(to: home)              // Walk away again by a non-sidebar route
        _ = await pollFS { pane.uiTestCurrentURL.standardizedFileURL.path
                            == home.standardizedFileURL.path }
        try? await Task.sleep(for: .milliseconds(200))
        // Force the highlight back to "Documents" to reproduce the "click the selected row" state
        sidebar.syncSelection(to: docs)
        try? await Task.sleep(for: .milliseconds(120))
        let highlightedBefore = sidebar.uiTestSelectedURL?.standardizedFileURL.path
        sidebar.uiTestClickRow(rowDocs)      // This clicks the row that is **already highlighted**
        let backToDocs = await pollFS { pane.uiTestCurrentURL.standardizedFileURL.path
                                         == docs.standardizedFileURL.path }
        record(toDocs && highlightedBefore == docs.standardizedFileURL.path && backToDocs,
               "I-68 clicking the already highlighted sidebar row still navigates (first entry=\(toDocs) highlighted before click=\(highlightedBefore == docs.standardizedFileURL.path) arrived after re-click=\(backToDocs))")

        // ④ the highlight really follows: entering a bookmark item must highlight it
        record(sidebar.uiTestSelectedURL?.standardizedFileURL.path == docs.standardizedFileURL.path
               && sidebar.uiTestClickWiredToOutline,
               "I-68 sidebar highlight points to the bookmark directory while there (highlight=\(sidebar.uiTestSelectedURL?.lastPathComponent ?? "none") click wired=\(sidebar.uiTestClickWiredToOutline))")

        pane.navigate(to: home)
        try? await Task.sleep(for: .milliseconds(200))
    }

    /// Enter through the shortcut: ① find the menu item bound to this key equivalent in the **real assembled main menu** (verifies "binding table → menu item"),
    /// ② dispatch its action along the responder chain of the **window under test** (verifies "menu item → responder chain → behaviour").
    /// Not NSApp.sendEvent / performKeyEquivalent: that route targets via the **key window**, while the self-test runs on
    /// a machine the user is using, where the app is often inactive and the key window nil; measured "key handled=true but
    /// the window under test did not budge". `tryToPerform` matches the existing I-57 convention and does not depend on activation.
    private static func pressMenuShortcut(_ key: String, mods: NSEvent.ModifierFlags,
                                          window: NSWindow) -> (found: Bool, delivered: Bool) {
        guard let item = menuItem(for: key, mods: mods), let action = item.action else {
            return (false, false)
        }
        window.makeFirstResponder(window.initialFirstResponder ?? window.contentView)
        return (true, window.tryToPerform(action, with: item))
    }

    /// Find a menu item by key equivalent in the assembled main menu, **lookup only, no execution**.
    /// This is what the retirement proof needs: pressMenuShortcut really dispatches the action it finds,
    /// and "what is this key still bound to" is exactly the unknown; running it would execute a command in the self-test that we never meant to run.
    private static func menuItem(for key: String, mods: NSEvent.ModifierFlags) -> NSMenuItem? {
        func find(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.keyEquivalent == key,
                   item.keyEquivalentModifierMask.intersection([.command, .option, .shift, .control])
                    == mods.intersection([.command, .option, .shift, .control]) { return item }
                if let sub = item.submenu, let hit = find(sub) { return hit }
            }
            return nil
        }
        guard let main = NSApp.mainMenu else { return nil }
        return find(main)
    }

    /// Scenario I-70/71/72 (three user reports, and my previous round fixed the wrong key; this time each enters from the key the user pressed):
    /// I-70 ⌘T new workspace must copy the current workspace (layout + each pane's sort/hidden/view mode), not fall back to global defaults;
    /// I-71 ⌥⌘T / ⌥⌘W retired with in-pane tabs; pins that they are no longer in the menu;
    /// I-72 clicking text in the workspace tab bar must switch, and the full row height must be clickable (root cause: NSTextField swallowing mouseDown).
    private static func runWorkspaceTabScenario(wc: MainWindowController, window: NSWindow) async {
        let fs = FileManager.default
        let tok = String(UUID().uuidString.prefix(8))
        let box = fs.temporaryDirectory.appendingPathComponent("hspace-uitest-i70-\(tok)", isDirectory: true)
        try? fs.createDirectory(at: box, withIntermediateDirectories: true)
        for i in 1...3 { try? Data("x".utf8).write(to: box.appendingPathComponent("w\(i).txt")) }
        record(assertSandboxed(box), "Sandbox guard [I-70]: workspace fixture inside own temp directory")
        guard assertSandboxed(box) else { return }
        defer { try? fs.removeItem(at: box) }

        // Dual panes, so "every pane inherits" means something
        wc.grid.apply(layout: .dualH)
        try? await Task.sleep(for: .milliseconds(250))
        let p0 = wc.grid.visiblePanes[0], p1 = wc.grid.visiblePanes[1]
        for p in [p0, p1] {
            p.uiTestEndPathEditing()
            p.navigate(to: box)
        }
        _ = await pollFS { p0.activeTab.model.items.count == 3 && p1.activeTab.model.items.count == 3 }
        // Give the two panes **different** non-default sorts: one "global default" alone cannot produce both
        let hiddenDefault = Preferences.showHiddenByDefault
        p0.uiTestSetSort(key: "dateModified", ascending: false); p0.uiTestSetIncludeHidden(!hiddenDefault)
        p1.uiTestSetSort(key: "size", ascending: true)
        wc.grid.setActivePane(0)
        try? await Task.sleep(for: .milliseconds(200))

        // ── I-70: ⌘T through the real menu key equivalent ──
        let wsBefore = wc.workspaces.count
        let press = pressMenuShortcut("t", mods: [.command], window: window)
        _ = await pollFS { wc.workspaces.count == wsBefore + 1 }
        try? await Task.sleep(for: .milliseconds(400))
        let n0 = wc.grid.visiblePanes.count > 0 ? wc.grid.visiblePanes[0] : nil
        let n1 = wc.grid.visiblePanes.count > 1 ? wc.grid.visiblePanes[1] : nil
        let s0 = n0?.uiTestModelSort, s1 = n1?.uiTestModelSort
        let layoutKept = wc.grid.layout == .dualH
        let inherited = s0?.key == "dateModified" && s0?.ascending == false
            && n0?.activeTab.model.includeHidden == !hiddenDefault
            && s1?.key == "size" && s1?.ascending == true
        record(press.found && press.delivered && wc.workspaces.count == wsBefore + 1 && layoutKept && inherited,
               "I-70 ⌘T new workspace copies the current workspace (menu has ⌘T item=\(press.found) delivered via responder chain=\(press.delivered) workspaces \(wsBefore)→\(wc.workspaces.count) dual layout kept=\(layoutKept) left \(s0.map { "\($0.key)/\($0.ascending ? "asc" : "desc")" } ?? "nil") hidden=\(n0?.activeTab.model.includeHidden ?? false)(default \(hiddenDefault)) right \(s1.map { "\($0.key)/\($0.ascending ? "asc" : "desc")" } ?? "nil"))")

        // ── I-72: workspace tab bar: clicking text switches, full row height clickable ──
        let bar = wc.deck.workspaceTabBar
        window.contentView?.layoutSubtreeIfNeeded(); bar.layoutSubtreeIfNeeded()
        let activeWS = wc.workspaces.activeIndex
        let targetWS = activeWS == 0 ? 1 : 0          // Click an **inactive** workspace
        if let f = bar.uiTestItemFrame(targetWS) {
            let onText = NSPoint(x: f.midX, y: f.midY)                // Dead center of the text (swallowed by NSTextField in the old version)
            let onEdge = NSPoint(x: f.midX, y: 1)                      // Row top edge (a dead zone in the old version → dragged the window)
            let hitText = bar.uiTestHitsItem(targetWS, at: onText)
            let hitEdge = bar.uiTestHitsItem(targetWS, at: onEdge)
            // Bar: hit resolves to the pod + delivering mouseDown to the resolved view really switches + accepts the first click.
            // Real window-level dispatch is diagnostic only: it passes one more app activation gate, which randomly eats the first click while the user is on the machine (real gate: 1 green, 2 red in 3 runs).
            let hitType = bar.uiTestClickResolved(at: onText, in: window)
            try? await Task.sleep(for: .milliseconds(350))
            let switched = wc.workspaces.activeIndex == targetWS
            let firstMouse = bar.uiTestItemAcceptsFirstMouse(targetWS)
            // Diagnostic: can window-level dispatch switch it back
            bar.uiTestClick(at: NSPoint(x: (bar.uiTestItemFrame(activeWS)?.midX ?? 0), y: f.midY), in: window)
            try? await Task.sleep(for: .milliseconds(350))
            let windowDispatchSwitchedBack = wc.workspaces.activeIndex == activeWS
            if !windowDispatchSwitchedBack { wc.switchWorkspace(to: activeWS) }   // The diagnostic must not affect later state
            record(hitText && hitEdge && switched && firstMouse,
                   "I-72 workspace tab bar switches on text click and the full row is clickable (hit on text=\(hitText) hit on row top=\(hitEdge) hit view=\(hitType) active after click \(activeWS)→\(targetWS)=\(switched) accepts first click=\(firstMouse) | diagnostic: window-level dispatch switched back=\(windowDispatchSwitchedBack))")
        } else {
            record(false, "I-72 workspace tab bar switches on text click and the full row is clickable (cannot get pod \(targetWS))")
        }

        // ── I-71: ⌥⌘T / ⌥⌘W retired along with in-pane tabs ──
        // Deleting the old assertion without leaving evidence means nobody would notice if these keys were rewired. This pins "really gone from the menu":
        // pressMenuShortcut the found of pressMenuShortcut checks directly whether the **assembled main menu** has an item bound to this key equivalent.
        // Lookup only: these two keys bind to nothing now, but if another command is ever bound to them,
        // really dispatching would run an action in the self-test that we do not want to run.
        let paneTabItem = menuItem(for: "t", mods: [.command, .option])
        let paneCloseItem = menuItem(for: "w", mods: [.command, .option])
        record(paneTabItem == nil && paneCloseItem == nil,
               "I-71 in-pane tabs retired: ⌥⌘T/⌥⌘W no longer bind any menu item (⌥⌘T hit=\(paneTabItem?.title ?? "none") ⌥⌘W hit=\(paneCloseItem?.title ?? "none"))")

        // Wrap up: close the new workspace, restore the layout
        while wc.workspaces.count > wsBefore { wc.closeWorkspace(at: wc.workspaces.count - 1) }
        try? await Task.sleep(for: .milliseconds(200))
        wc.grid.apply(layout: .single)
        let home = fs.homeDirectoryForCurrentUser
        let hp = wc.grid.activePane
        hp.uiTestSetIncludeHidden(hiddenDefault); hp.uiTestSetSort(key: "name", ascending: true)
        hp.navigate(to: home)
        try? await Task.sleep(for: .milliseconds(200))
    }

    private static func runPasteAndRenameScenario(wc: MainWindowController, window: NSWindow) async {
        let fs = FileManager.default
        let pane = wc.grid.activePane
        let tok = String(UUID().uuidString.prefix(8))
        let box = fs.temporaryDirectory
            .appendingPathComponent("hspace-uitest-i65-\(tok)", isDirectory: true)
        try? fs.createDirectory(at: box, withIntermediateDirectories: true)
        record(assertSandboxed(box), "Sandbox guard [I-65]: paste/rename fixture inside own temp directory")
        guard assertSandboxed(box) else { return }
        defer { try? fs.removeItem(at: box) }

        // ① clipboard derivation: image before text. When a browser copies an image, the clipboard holds **both** a PNG and some HTML
        //   text; preferring text would give the user a .txt instead of the image. The order is the priority, and it must stay pinned.
        let pbImg = NSPasteboard(name: NSPasteboard.Name("hspace.uitest.i65a.\(tok)"))
        pbImg.clearContents()
        pbImg.setString("<img src=...>", forType: .string)
        pbImg.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
        let imgPayload = FileOpsCoordinator.contentPayload(from: pbImg)

        let pbTxt = NSPasteboard(name: NSPasteboard.Name("hspace.uitest.i65b.\(tok)"))
        pbTxt.clearContents()
        pbTxt.setString("hello", forType: .string)
        let txtPayload = FileOpsCoordinator.contentPayload(from: pbTxt)

        let pbEmpty = NSPasteboard(name: NSPasteboard.Name("hspace.uitest.i65c.\(tok)"))
        pbEmpty.clearContents()
        pbEmpty.setString("", forType: .string)
        let emptyPayload = FileOpsCoordinator.contentPayload(from: pbEmpty)

        record(imgPayload?.name.hasSuffix(".png") == true
               && imgPayload?.data == Data([0x89, 0x50, 0x4E, 0x47])
               && txtPayload?.name.hasSuffix(".txt") == true
               && txtPayload?.data == Data("hello".utf8)
               && emptyPayload == nil,
               "I-65 clipboard derivation: image before text, empty content makes no file (image=\(imgPayload?.name ?? "nil") text=\(txtPayload?.name ?? "nil") empty=\(emptyPayload == nil ? "nil" : "non-nil"))")

        // ② ⌘V really lands as a new file (real coordinator chain → kernel → LocalOps write)
        pane.uiTestEndPathEditing()
        pane.navigate(to: box)
        _ = await pollFS { pane.uiTestViewCurrentDirectory.standardizedFileURL.path
                            == box.standardizedFileURL.path }
        wc.coordinator.pasteContentAsNewFile(into: box, from: pbTxt)
        let landed = await pollFS {
            ((try? fs.contentsOfDirectory(atPath: box.path)) ?? []).contains { $0.hasSuffix(".txt") }
        }
        let name = ((try? fs.contentsOfDirectory(atPath: box.path)) ?? []).first { $0.hasSuffix(".txt") }
        let body = name.flatMap { try? Data(contentsOf: box.appendingPathComponent($0)) }
        record(landed && body == Data("hello".utf8),
               "I-65 ⌘V pastes clipboard content as a new file (landed=\(landed) name=\(name ?? "nil") content matches=\(body == Data("hello".utf8)))")
        pbImg.releaseGlobally(); pbTxt.releaseGlobally(); pbEmpty.releaseGlobally()

        // ③ click-to-rename predicate (pure function, deterministic): multi-selection belongs to I-43's collapse, the two do not compete for one gesture
        let renameSingle = FocusReportingTableView.shouldScheduleRename(
            clickedRow: 3, modifiers: [], clickCount: 1,
            selectedCount: 1, rowIsSelected: true, isGroupRow: false)
        let renameUnselected = FocusReportingTableView.shouldScheduleRename(
            clickedRow: 3, modifiers: [], clickCount: 1,
            selectedCount: 1, rowIsSelected: false, isGroupRow: false)
        let renameMulti = FocusReportingTableView.shouldScheduleRename(
            clickedRow: 3, modifiers: [], clickCount: 1,
            selectedCount: 3, rowIsSelected: true, isGroupRow: false)
        let renameDouble = FocusReportingTableView.shouldScheduleRename(
            clickedRow: 3, modifiers: [], clickCount: 2,
            selectedCount: 1, rowIsSelected: true, isGroupRow: false)
        let renameModified = FocusReportingTableView.shouldScheduleRename(
            clickedRow: 3, modifiers: [.command], clickCount: 1,
            selectedCount: 1, rowIsSelected: true, isGroupRow: false)
        let renameGroup = FocusReportingTableView.shouldScheduleRename(
            clickedRow: 3, modifiers: [], clickCount: 1,
            selectedCount: 1, rowIsSelected: true, isGroupRow: true)
        record(renameSingle && !renameUnselected && !renameMulti
               && !renameDouble && !renameModified && !renameGroup,
               "I-65 click-to-rename predicate: true only for 'single selection + click on selected row + no modifier + single click' (selected=\(renameSingle) unselected=\(renameUnselected) multi=\(renameMulti) double=\(renameDouble) modified=\(renameModified) group header=\(renameGroup))")

        // ④ the bottom always keeps a right-clickable blank area (somewhere to click even when content fills the view).
        //   Uses the real scrollView's contentInsets and the really injected callback, with no copied constants and no direct buildMenu calls.
        window.contentView?.layoutSubtreeIfNeeded()
        let tailOK = FileListViewController.blankTailHeight >= 24
        let insetOK = pane.uiTestListBottomInset == FileListViewController.blankTailHeight
        let blankMenu = pane.uiTestBlankAreaMenu()
        let blankHasNewFile = blankMenu?.items.contains {
            $0.action == #selector(FileListViewController.newFileHere(_:))
        } ?? false
        record(tailOK && insetOK && blankHasNewFile,
               "I-65 list bottom blank area right-clicks to the New menu (blank \(Int(FileListViewController.blankTailHeight))pt inset=\(Int(pane.uiTestListBottomInset)) menu has New File=\(blankHasNewFile))")

        // ⑤ new file has a shortcut that does not collide with new folder
        let nf = KeyBindings.display("newFile")
        let nd = KeyBindings.display("newFolder")
        // Unbound display returns an em dash "—", **not an empty string**: the first version wrote !nf.isEmpty,
        // which stayed green with newFile's default binding removed (false green, caught by a counter-test). What matters is "really has a key".
        let bound = KeyBindings.binding("newFile")
        record(!bound.key.isEmpty && nf != "—" && nf != nd,
               "I-65 New File has a shortcut with no New Folder conflict (New File=\(nf) New Folder=\(nd) really has key=\(!bound.key.isEmpty))")

        pane.navigate(to: fs.homeDirectoryForCurrentUser)
        try? await Task.sleep(for: .milliseconds(200))
    }

    /// Scenario I-66: settings search at the top of the settings window: the user wants "every setting searchable and able to jump to its item".
    /// The index is read live from the **assembled view tree**, so the assertions hit the real index and the real jump.
    private static func runSettingsSearchScenario(window: NSWindow) async {
        let sc = SettingsWindowController.shared
        sc.showWindow(nil)
        try? await Task.sleep(for: .milliseconds(400))
        sc.window?.contentView?.layoutSubtreeIfNeeded()

        // ① the index was really built, and covers multiple tabs (one page only = the traversal fell short)
        let idxCount = sc.uiTestSearchIndexCount
        let texts = sc.uiTestSearchIndexTexts
        record(idxCount >= 20 && !texts.isEmpty,
               "I-66 settings index built from the real view tree (\(idxCount) items)")

        // ② search for an entry that **really exists** in the index (no hardcoded word: this should go red when copy changes,
        //    but not because I guessed the word wrong)
        let sample = texts.first { $0.count >= 2 && $0.count <= 12 } ?? texts.first ?? ""
        let probe = String(sample.prefix(3))
        sc.applySearch(probe)
        try? await Task.sleep(for: .milliseconds(150))
        let hitCount = sc.uiTestSearchResultCount
        let listShown = sc.uiTestSearchResultsVisible
        record(!probe.isEmpty && hitCount > 0 && listShown,
               "I-66 results appear on input (searching '\(probe)' got \(hitCount), results visible=\(listShown))")

        // ③ clicking a result → really switches to that page (the jump is the core of this feature, "findable" alone is not enough)
        let wantTab = sc.uiTestSearchResultTabIndex(0)
        // First switch to another page on purpose, or "already on that page" would pass the assertion vacuously
        sc.uiTestSelectTab(wantTab == 0 ? 1 : 0)
        try? await Task.sleep(for: .milliseconds(150))
        let before = sc.uiTestSelectedTabIndex
        let jumped = sc.jumpToResult(0)
        try? await Task.sleep(for: .milliseconds(250))
        let after = sc.uiTestSelectedTabIndex
        record(jumped && wantTab >= 0 && before != wantTab && after == wantTab,
               "I-66 clicking a result jumps to its tab (before \(before) → after \(after), target \(wantTab))")

        // ④ clear search → results area collapses (otherwise it keeps occupying the top of the settings window)
        sc.applySearch("")
        try? await Task.sleep(for: .milliseconds(150))
        record(sc.uiTestSearchResultCount == 0 && !sc.uiTestSearchResultsVisible,
               "I-66 results area collapses after clearing search (count \(sc.uiTestSearchResultCount) visible=\(sc.uiTestSearchResultsVisible))")

        sc.window?.close()
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(200))
    }

    private static func runTrashNavigationScenario(wc: MainWindowController, window: NSWindow) async {
        let fs = FileManager.default
        let pane = wc.grid.activePane
        // User's words: "hspace lacks a Trash feature, clicking Trash still jumps to Finder; ...the Trash button with the icon at the top right
        // should jump straight to the Trash when clicked".
        // Before: that trash button's action was moveToTrash with `isEnabled = hasSelection`,
        // grayed out with no selection → the user concluded "this feature does not exist"; the app had **no path at all** to the Trash.
        // Hard rule: touch only self-created hspace-uitest-i62-* fixtures; test items landing in the real Trash are cleaned up by token.
        do {
            let token = String(UUID().uuidString.prefix(8))
            let box = fs.temporaryDirectory
                .appendingPathComponent("hspace-uitest-i62-\(token)", isDirectory: true)
            let victimName = "hspace-uitest-i62-\(token)-victim.txt"
            let victim = box.appendingPathComponent(victimName)
            try? fs.createDirectory(at: box, withIntermediateDirectories: true)
            try? Data("x".utf8).write(to: victim)
            let g62 = assertSandboxed(victim)
            record(g62, "Sandbox guard [I-62]: Trash fixture inside own temp directory")

            if g62 {
                pane.uiTestEndPathEditing()
                pane.navigate(to: box)
                _ = await pollFS { pane.uiTestViewCurrentDirectory.standardizedFileURL.path
                                    == box.standardizedFileURL.path }
                // ① the trash button must be usable with no selection (always gray before; that was the "missing feature" the user saw)
                pane.uiTestClearSelection()
                wc.deck.validateActions(hasSelection: false)
                try? await Task.sleep(for: .milliseconds(120))
                let enabledNoSel = wc.deck.uiTestTrashButtonEnabled
                record(enabledNoSel,
                       "I-62 deck trash button usable with empty selection (usable=\(enabledNoSel))")

                // ② dragging a file onto the trash button → really moved to Trash.
                //   Placed before "click to navigate" on purpose: when counting Trash items below, it surely holds the item
                //   we made, so the assertion no longer depends on "the user's real Trash is not empty" (it would always be red on a machine with an empty Trash).
                let dragRegistered = wc.deck.uiTestTrashAcceptsFileURLDrags
                let pb = NSPasteboard(name: NSPasteboard.Name("hspace.uitest.i62.\(UUID().uuidString)"))
                pb.clearContents()
                pb.writeObjects([victim as NSURL])
                let accepted = wc.deck.uiTestDropOnTrash(from: pb)
                let gone = accepted ? (await pollFS { !fs.fileExists(atPath: victim.path) }) : false
                let inTrash = await pollFS {
                    ((try? fs.contentsOfDirectory(atPath: TrashLocation.userTrash.path)) ?? [])
                        .contains { $0.hasPrefix("hspace-uitest-i62-\(token)") }
                }
                // dragRegistered cannot be dropped: the injection seam verifies only the drop logic, not whether AppKit
                // will deliver the drag to this button (that needs registerForDraggedTypes)
                record(accepted && gone && inTrash && dragRegistered,
                       "I-62 drag onto trash button → really moved to Trash (accepted=\(accepted) source gone=\(gone) in Trash=\(inTrash) fileURL drag registered=\(dragRegistered))")
                pb.releaseGlobally()

                // ③ click → navigate to ~/.Trash **inside the app** (through the button's real action → deck exit → pane)
                wc.deck.uiTestClickTrash()
                let arrived = await pollFS {
                    TrashLocation.isTrash(pane.uiTestCurrentURL)
                }
                record(arrived && TrashLocation.isTrash(pane.uiTestBreadcrumbURL),
                       "I-62 clicking trash button → navigates to Trash in-app (landed=\(pane.uiTestCurrentURL.lastPathComponent) breadcrumb=\(pane.uiTestBreadcrumbURL.lastPathComponent))")

                // ③ Trash contents are really listed (~/.Trash itself carries the hidden flag,
                //    so do not just check "navigated there"; a blank list would still pass)
                // The on-disk convention must **follow the model's current** includeHidden, not assume false:
                // earlier scenarios (I-55 etc) turn on "show hidden files" and may not restore it;
                // a hardcoded .skipsHiddenFiles compared 15 with the model's 17 (exactly how this went red when first written).
                @MainActor func trashCountOnDisk() -> Int {
                    let opts: FileManager.DirectoryEnumerationOptions =
                        pane.activeTab.model.includeHidden ? [] : [.skipsHiddenFiles]
                    return (try? fs.contentsOfDirectory(
                        at: TrashLocation.userTrash, includingPropertiesForKeys: nil,
                        options: opts))?.count ?? -1
                }
                // Wait until the model has really switched to the Trash before sampling: an always-true wait like `count >= 0` is no wait,
                // and samples the previous directory's stale count (when first written it sampled box's 1 item).
                let listed = await pollFS {
                    TrashLocation.isTrash(pane.uiTestViewCurrentDirectory)
                        && pane.activeTab.model.items.count == trashCountOnDisk()
                }
                let trashItemCount = pane.activeTab.model.items.count
                let onDisk = trashCountOnDisk()
                record(listed && trashItemCount == onDisk && onDisk > 0,
                       "I-62 Trash contents really listed (list \(trashItemCount) items == disk \(onDisk) items, hidden=\(pane.activeTab.model.includeHidden))")

                // ⑤ the Go menu has a "Trash" item wired to goTrash (a second route besides the deck, not just one entry point)
                let goHit = MainMenu.uiTestMenuItem(for: #selector(PaneViewController.goTrash(_:)))
                // More than "goTrash exists somewhere in the tree": it must be under the Go menu, with the right title, and really clickable
                let inGoMenu = goHit?.ownerTitle == L10n.t("menu.go")
                let usable = goHit.map { $0.item.isEnabled || $0.item.target == nil } ?? false
                record(goHit != nil && goHit?.item.title == L10n.t("menu.goTrash") && inGoMenu && usable,
                       "I-62 Go menu has a 'Trash' item wired to goTrash (title=\(goHit?.item.title ?? "nil") owner=\(goHit?.ownerTitle ?? "nil") usable=\(usable))")

                // ⑥ routing seam for cross-window drops: look up the controller by window.
                //   When dragging across to another window's deck, undo and the toast must belong to the **source window**,
                //   or ⌘Z does nothing in the source window and the toast shows on a window that may be covered.
                let del = NSApp.delegate as? AppDelegate
                let ownFound = del?.mainWindowController(for: window) === wc
                let strangerWin = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                                           styleMask: [.borderless], backing: .buffered, defer: true)
                let strangerNil = del?.mainWindowController(for: strangerWin) == nil
                let nilIsNil = del?.mainWindowController(for: nil) == nil
                record(ownFound && strangerNil && nilIsNil,
                       "I-62 controller lookup by window (own hit=\(ownFound) stranger window empty=\(strangerNil) nil empty=\(nilIsNil))")

                // Cleanup: delete test items in the real Trash by token (unique names, safe)
                if let entries = try? fs.contentsOfDirectory(atPath: TrashLocation.userTrash.path) {
                    for e in entries where e.hasPrefix("hspace-uitest-i62-\(token)") {
                        try? fs.removeItem(at: TrashLocation.userTrash.appendingPathComponent(e))
                    }
                }
            }
            pane.navigate(to: fs.homeDirectoryForCurrentUser)
            try? await Task.sleep(for: .milliseconds(200))
            if assertSandboxed(box) { try? fs.removeItem(at: box) }
        }
    }

    private static func runTrashOperationsScenario(wc: MainWindowController, window: NSWindow) async {
        let fs = FileManager.default
        let pane = wc.grid.activePane
        // ── Scenario I-63: Empty Trash (irreversible) + Put Back ────────────────────────
        // The user explicitly asked for both. Emptying goes through the new Eraser pod (`.delete` + fence root),
        // Put Back through the new TrashLedger pod (macOS put-back metadata lives in a private Finder library and cannot be read:
        // measured, the only xattr is an empty com.apple.provenance, and Finder's own AppleScript cannot get it either).
        // Hard rule: **the emptying half is verified only on a self-made temp fixture**, never touching the user's real Trash;
        //       the Put Back half must go through the real Trash (the true target), but touches only own token items and must put them back.
        do {
            let tok = String(UUID().uuidString.prefix(8))

            // ① keep the deck context menu entry; the main entry is verified separately in I-64.
            let cm = wc.deck.uiTestTrashContextMenu()
            let hasEmpty = cm?.items.contains { $0.title == L10n.t("menu.emptyTrash") } ?? false
            let wired = cm?.items.first?.action != nil && cm?.items.first?.target != nil
            record(cm?.items.count == 1 && hasEmpty && wired,
                   "I-63 trash button context menu has 'Empty Trash' (\(cm?.items.count ?? -1) items hit=\(hasEmpty) wired=\(wired))")

            // ② the working half of emptying: run on a **self-made temp fixture**, never touch the real Trash
            let fakeTrash = fs.temporaryDirectory
                .appendingPathComponent("hspace-uitest-i63-\(tok)-trash", isDirectory: true)
            try? fs.createDirectory(at: fakeTrash.appendingPathComponent("dir"),
                                    withIntermediateDirectories: true)
            try? Data("a".utf8).write(to: fakeTrash.appendingPathComponent("a.txt"))
            try? Data("b".utf8).write(to: fakeTrash.appendingPathComponent(".hidden-b"))
            try? Data("c".utf8).write(to: fakeTrash.appendingPathComponent("dir/c.txt"))
            record(assertSandboxed(fakeTrash), "Sandbox guard [I-63]: empty fixture inside own temp directory")
            let victims = (try? fs.contentsOfDirectory(at: fakeTrash,
                                                       includingPropertiesForKeys: nil,
                                                       options: [])) ?? []
            let victimCount = victims.count
            if assertSandboxed(fakeTrash), victimCount == 3 {
                // Return key behaviour is verified on a temp fence; never send Return to a real Trash confirmation.
                wc.coordinator.emptyTrash(at: fakeTrash, in: window)
                // Take the foreground back before waiting: `isKeyWindow` requires the whole app to be active;
                // if another app (or a concurrently running HSpace instance) grabs focus it never arrives
                // (red 2 of 6 real-gate runs).
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                // Pin the bar on **the alert really appearing** (deterministic); `isKeyWindow` is diagnostic output only.
                // This assertion must prove "Return cannot delete the files", which does not depend on whether the sheet is key.
                let sheetReady = await pollFS { window.attachedSheet != nil }
                // Wait for activation to really land (activate is async); if it does not, do not expect Return to get through
                let appActive = await pollFS { NSApp.isActive && window.attachedSheet?.isKeyWindow == true }
                // **Deterministic bar**: the guarantee that "Return cannot delete" is the key binding itself, which can be checked without a key window.
                // Whether Return really gets through depends on the app being active (when another app holds focus NSApp.sendEvent
                // does not reach it); making that the bar would flake with the environment: real gate red 2 of 6, then after adding activate
                // red 2 of 3 more, as measured.
                //
                // It must read **the button's own keyEquivalent**, not window.defaultButtonCell:
                // the latter is an old draw-time API, and setting it does not move "\r" to the Cancel button. It once passed because
                // the sheet was key and AppKit happened to sync; with the app inactive no sync occurs,
                // so Return stayed bound to "Empty": reproduced steadily over three real-gate runs, a true defect and not a false red.
                let sheetButtons = viewTree(window.attachedSheet?.contentView).compactMap { $0 as? NSButton }
                let confirmKey = sheetButtons.first { $0.title == L10n.t("alert.emptyTrash.confirm") }?
                    .keyEquivalent
                let cancelKey = sheetButtons.first { $0.title == L10n.t("common.cancel") }?.keyEquivalent
                // "Empty" holds no Return and Esc sits on "Cancel". The former is the safety invariant itself;
                // the latter pins that an exit remains; otherwise removing both keys would satisfy the former and only clicking could close the alert.
                let enterHarmless = confirmKey != nil && confirmKey != "\r" && cancelKey == "\u{1b}"
                var returnSent = false
                if let sheet = window.attachedSheet,
                   let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: sheet.windowNumber, context: nil,
                           characters: "\r", charactersIgnoringModifiers: "\r",
                           isARepeat: false, keyCode: 36) {
                    NSApp.sendEvent(event)
                    returnSent = true
                }
                let returnClosed = await pollFS { window.attachedSheet == nil }
                let returnKeptFiles = victims.allSatisfy { fs.fileExists(atPath: $0.path) }
                // Bar = the alert really appears + Return not bound to "Empty" (Esc exit still there) + no file missing;
                // "Return was delivered and closed the alert" is no longer required: with Esc as cancel, Return has no effect at all
                record(sheetReady && enterHarmless && returnKeptFiles,
                       "I-63 Return on the empty confirmation does not trigger emptying (alert shown=\(sheetReady) Return harmless=\(enterHarmless) three items remain=\(returnKeptFiles) | diagnostic: app active=\(appActive) Return sent=\(returnSent) closed=\(returnClosed) empty key=\(confirmKey?.isEmpty == true ? "none" : (confirmKey ?? "?")) cancel key=Esc:\(cancelKey == "\u{1b}"))")
                if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .abort) }

                wc.coordinator.emptyTrash(at: fakeTrash, in: window)
                _ = await pollFS { window.attachedSheet != nil }
                let confirm = viewTree(window.attachedSheet?.contentView).compactMap { $0 as? NSButton }
                    .first { $0.title == L10n.t("alert.emptyTrash.confirm") }
                let confirmed = confirm != nil
                confirm?.performClick(nil)
                if confirm == nil, let sheet = window.attachedSheet {
                    window.endSheet(sheet, returnCode: .abort)
                }
                _ = await pollFS { window.attachedSheet == nil }
                let emptied = await pollFS {
                    ((try? fs.contentsOfDirectory(atPath: fakeTrash.path)) ?? []).isEmpty
                }
                // The fence root itself must remain (emptying clears content, not the directory)
                let fenceAlive = fs.fileExists(atPath: fakeTrash.path)
                record(confirmed && emptied && fenceAlive,
                       "I-63 Empty Trash really deletes content and keeps the Trash itself (really clicked confirm=\(confirmed) emptied=\(emptied) Trash remains=\(fenceAlive) originally \(victimCount) items including a dotfile)")
            } else {
                record(false, "I-63 Empty Trash really deletes content and keeps the Trash itself (fixture unexpected, \(victimCount) items)")
            }
            try? fs.removeItem(at: fakeTrash)

            // ③ Put Back round trip: really delete a self-made item → ledger records it → put back → returns to its original location
            let pbBox = fs.temporaryDirectory
                .appendingPathComponent("hspace-uitest-i63-\(tok)-pb", isDirectory: true)
            let pbFile = pbBox.appendingPathComponent("hspace-uitest-i63-\(tok)-pb.txt")
            try? fs.createDirectory(at: pbBox, withIntermediateDirectories: true)
            try? Data("putback".utf8).write(to: pbFile)
            if assertSandboxed(pbFile) {
                wc.coordinator.moveToTrash([pbFile])
                let gone = await pollFS { !fs.fileExists(atPath: pbFile.path) }
                // The ledger must have a record (otherwise "Put Back" is an empty promise)
                var recorded: URL?
                var menuDispatched = false
                if let led = wc.coordinator.trashLedger {
                    let trashed = TrashLocation.userTrash
                        .appendingPathComponent(pbFile.lastPathComponent)
                    for _ in 0..<30 {
                        if let o = await led.origin(of: trashed) { recorded = o; break }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    if recorded != nil {
                        pane.setViewMode(.list)
                        pane.navigate(to: TrashLocation.userTrash)
                        _ = await pollFS { pane.activeTab.model.items.contains { samePath($0.url, trashed) } }
                        let list = pane.activeTab.listVC
                        list.select(urls: [trashed])
                        let table = list.tableView
                        let row = table.selectedRow
                        if row >= 0 {
                            table.scrollRowToVisible(row)
                            window.contentView?.layoutSubtreeIfNeeded()
                            let rect = table.rect(ofRow: row)
                            let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
                            if let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point,
                                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil,
                                    eventNumber: 0, clickCount: 1, pressure: 1),
                               let menu = table.menu(for: event) {
                                menu.update()
                                if let index = menu.items.firstIndex(where: {
                                    $0.action == #selector(FileListViewController.putBackItems(_:)) && $0.isEnabled
                                }) {
                                    menu.performActionForItem(at: index)
                                    menuDispatched = true
                                }
                            }
                        }
                    }
                }
                let back = await pollFS { fs.fileExists(atPath: pbFile.path) }
                let content = (try? Data(contentsOf: pbFile)) == Data("putback".utf8)
                record(gone && recorded?.standardizedFileURL.path == pbFile.standardizedFileURL.path
                       && menuDispatched && back && content,
                       "I-63 Put Back round trip (deleted=\(gone) ledger has record=\(recorded != nil) really clicked item menu=\(menuDispatched) returned to original location=\(back) content matches=\(content))")
            } else {
                record(false, "I-63 Put Back round trip (sandbox guard failed)")
            }
            // Wrap up: delete any token items left in the real Trash
            if let entries = try? fs.contentsOfDirectory(atPath: TrashLocation.userTrash.path) {
                for e in entries where e.contains("hspace-uitest-i63-\(tok)") {
                    try? fs.removeItem(at: TrashLocation.userTrash.appendingPathComponent(e))
                }
            }
            if assertSandboxed(pbBox) { try? fs.removeItem(at: pbBox) }

            // ④ honesty: items with no ledger record have no original location (items deleted by other apps must not pretend they can go back)
            if let led = wc.coordinator.trashLedger {
                let stranger = TrashLocation.userTrash
                    .appendingPathComponent("hspace-uitest-i63-\(tok)-stranger.txt")
                let noOrigin = await led.origin(of: stranger) == nil
                record(noOrigin,
                       "I-63 items with no ledger record must not pretend they can be put back (original location=\(noOrigin ? "nil" : "non-nil"))")
            } else {
                record(false, "I-63 items with no ledger record must not pretend they can be put back (ledger not injected)")
            }

            // ⑤ the menu switches by location: in the Trash it offers "Put Back" and not "Move to Trash", outside the reverse
            let lvc = pane.activeTab.listVC
            let inTrashMenu = FileContextMenuBuilder.menu(
                selection: [], directory: TrashLocation.userTrash, target: lvc)
            let itemsInTrash = FileContextMenuBuilder.menu(
                selection: pane.activeTab.listVC.selectedItems.isEmpty
                    ? [FileItem(url: TrashLocation.userTrash.appendingPathComponent("x"),
                                name: "x", isDirectory: false, isPackage: false,
                                isSymlink: false, isHidden: false, size: nil,
                                modified: nil, created: nil, added: nil,
                                contentTypeID: nil)]
                    : pane.activeTab.listVC.selectedItems,
                directory: TrashLocation.userTrash, target: lvc)
            let a1 = Set(itemsInTrash.items.compactMap { $0.action })
            let outside = FileContextMenuBuilder.menu(
                selection: [FileItem(url: fs.temporaryDirectory.appendingPathComponent("y"),
                                     name: "y", isDirectory: false, isPackage: false,
                                     isSymlink: false, isHidden: false, size: nil,
                                     modified: nil, created: nil, added: nil,
                                     contentTypeID: nil)],
                directory: fs.temporaryDirectory, target: lvc)
            let a2 = Set(outside.items.compactMap { $0.action })
            let putBackSel = #selector(FileListViewController.putBackItems(_:))
            let trashSel = #selector(FileListViewController.moveToTrash(_:))
            record(a1.contains(putBackSel) && !a1.contains(trashSel)
                   && a2.contains(trashSel) && !a2.contains(putBackSel)
                   && inTrashMenu.items.count == 6,
                   "I-63 item menu switches between Put Back and Move to Trash by location (in Trash putBack=\(a1.contains(putBackSel)) moveIn=\(a1.contains(trashSel)); outside moveIn=\(a2.contains(trashSel)) putBack=\(a2.contains(putBackSel)); blank menu still \(inTrashMenu.items.count) items)")
        }
    }

    private static func runEmptyTrashButtonScenario(wc: MainWindowController, window: NSWindow) async {
        let fs = FileManager.default
        let pane = wc.grid.activePane
        let home = fs.homeDirectoryForCurrentUser
        let token = UUID().uuidString
        let box = fs.temporaryDirectory.appendingPathComponent("hspace-uitest-i64-\(token)")
        let folder = box.appendingPathComponent("hspace-uitest-i64-\(token)-folder")
        let trashed = TrashLocation.userTrash.appendingPathComponent(folder.lastPathComponent)
        let payload = Data("I-64 keep this fixture".utf8)
        guard assertSandboxed(folder), !fs.fileExists(atPath: trashed.path) else {
            record(false, "Sandbox guard [I-64]: subfolder fixture unavailable")
            return
        }
        // Make our own subfolder rather than rely on the user's Trash happening to have one; the real empty is only ever cancelled.
        defer {
            try? fs.removeItem(at: box)
            if fs.fileExists(atPath: trashed.path) { try? fs.removeItem(at: trashed) }
        }
        do {
            try fs.createDirectory(at: folder, withIntermediateDirectories: true)
            try payload.write(to: folder.appendingPathComponent("keep.txt"))
        } catch {
            record(false, "I-64 failed to create subfolder fixture: \(error)")
            return
        }
        wc.coordinator.moveToTrash([folder])
        let fixtureTrashed = await pollFS { fs.fileExists(atPath: trashed.appendingPathComponent("keep.txt").path) }
        guard fixtureTrashed else {
            record(false, "I-64 subfolder fixture did not reach the Trash")
            return
        }

        pane.uiTestEndPathEditing()
        pane.navigate(to: home)
        _ = await pollFS { samePath(pane.uiTestCurrentURL, home) }
        window.contentView?.layoutSubtreeIfNeeded()
        let hiddenOutside = !pane.uiTestEmptyTrashButtonVisible
        let zeroWidth = pane.uiTestEmptyTrashButtonWidth == 0

        wc.deck.uiTestClickTrash()
        _ = await pollFS { TrashLocation.isTrash(pane.uiTestCurrentURL) }
        try? await Task.sleep(for: .milliseconds(200))
        window.contentView?.layoutSubtreeIfNeeded()
        let shownInTrash = pane.uiTestEmptyTrashButtonVisible
        let hasWidth = pane.uiTestEmptyTrashButtonWidth > 0
        let titleOK = pane.uiTestEmptyTrashButtonTitle == L10n.t("trash.empty.button")
        capture(window, "31-trash-empty-button")
        record(hiddenOutside && zeroWidth && shownInTrash && hasWidth && titleOK,
               "I-64 'Empty' button appears only in the Trash (hidden outside=\(hiddenOutside) zero width=\(zeroWidth) shown inside=\(shownInTrash) width \(Int(pane.uiTestEmptyTrashButtonWidth)))")

        let before = Set((try? fs.contentsOfDirectory(atPath: TrashLocation.userTrash.path)) ?? [])
        let clicked = pane.uiTestClickEmptyTrashButton()
        let presented = clicked ? await pollFS { window.attachedSheet != nil } : false
        let sheet = window.attachedSheet
        let buttons = viewTree(sheet?.contentView).compactMap { $0 as? NSButton }
        let cancel = buttons.first { $0.title == L10n.t("common.cancel") }
        let confirm = buttons.first { $0.title == L10n.t("alert.emptyTrash.confirm") }
        // The criterion is **the button's own keyEquivalent**, not sheet.defaultButtonCell:
        // the latter is an old draw-time API that AppKit syncs only when the sheet becomes key,
        // App so with the app inactive it reads stale, while "Return does not empty" must hold unconditionally.
        // With "Cancel" in the first button slot AppKit gives it Escape by title, so Return binds no button (measured).
        let enterHarmless = confirm?.keyEquivalent != "\r" && cancel?.keyEquivalent == "\u{1b}"
        record(presented && enterHarmless && confirm?.hasDestructiveAction == true,
               "I-64 really clicking 'Empty' opens the in-window confirmation, Return does not trigger emptying (alert=\(presented) Return harmless=\(enterHarmless) empty key=\(confirm?.keyEquivalent.isEmpty == true ? "none" : "set") cancel key=Esc:\(cancel?.keyEquivalent == "\u{1b}"))")
        if let sheet { capture(sheet, "31b-trash-confirmation") }

        let cancelled = cancel != nil
        cancel?.performClick(nil)
        if cancel == nil, let sheet { window.endSheet(sheet, returnCode: .abort) }
        let dismissed = await pollFS { window.attachedSheet == nil }
        let after = Set((try? fs.contentsOfDirectory(atPath: TrashLocation.userTrash.path)) ?? [])
        let kept = (try? Data(contentsOf: trashed.appendingPathComponent("keep.txt"))) == payload
        record(cancelled && dismissed && before == after && kept,
               "I-64 cancelling Empty deletes nothing (really clicked Cancel=\(cancelled) closed=\(dismissed) items unchanged=\(before == after) fixture content unchanged=\(kept))")

        pane.beginPathEditing()
        let hiddenWhileEditing = !pane.uiTestEmptyTrashButtonVisible && pane.uiTestEmptyTrashButtonWidth == 0
        pane.uiTestEndPathEditing()
        window.contentView?.layoutSubtreeIfNeeded()
        let backAfterEditing = pane.uiTestEmptyTrashButtonVisible
        record(hiddenWhileEditing && backAfterEditing,
               "I-64 'Empty' button hides while editing the address and returns after (hidden while editing=\(hiddenWhileEditing) shown after=\(backAfterEditing))")

        pane.navigate(to: trashed)
        _ = await pollFS { samePath(pane.uiTestCurrentURL, trashed) }
        let hiddenInSubfolder = !pane.uiTestEmptyTrashButtonVisible && !pane.uiTestClickEmptyTrashButton()
        record(hiddenInSubfolder,
               "I-64 Trash subfolder does not show 'Empty' (own subfolder hidden and unclickable=\(hiddenInSubfolder))")
        pane.navigate(to: home)
        _ = await pollFS { samePath(pane.uiTestCurrentURL, home) }
        wc.coordinator.putBack([trashed])
        let restored = await pollFS { fs.fileExists(atPath: folder.appendingPathComponent("keep.txt").path) }
        record(restored && !fs.fileExists(atPath: trashed.path),
               "I-64 subfolder fixture put back (put back=\(restored) nothing left in Trash=\(!fs.fileExists(atPath: trashed.path)))")
        if let ledger = wc.coordinator.trashLedger {
            await ledger.forget([trashed])
        }
    }

    private static func runBreadcrumbHitScenario(wc: MainWindowController, window: NSWindow) async {
        let fs = FileManager.default
        let pane = wc.grid.activePane
        // ── Scenario I-61: breadcrumb segment hit boxes fill the address bar's full height + hit margin around segment names ──────────────
        // User's words: "in the address bar you must click the dead center of a folder for it to navigate, a little off and it does not,
        // it goes into typing mode instead". Root cause: place() shrank the frame height to intrinsicContentSize.height
        // and centered vertically; the 14pt segment / 6.5pt chevron sit in a 20pt bar with dead zones above and below,
        // and a click there falls through to BreadcrumbBar.mouseDown → onBeginEditing.
        // The assertion must hit the **hit area** (through NSView.hitTest, which AppKit itself uses to dispatch mouseDown);
        // a frame-only assertion still computes fine if place() reverts to short boxes and cannot catch "cannot be clicked".
        do {
            let token = String(UUID().uuidString.prefix(8))
            let base = fs.temporaryDirectory
                .appendingPathComponent("hspace-uitest-i61-\(token)", isDirectory: true)
            let deep = base.appendingPathComponent("alpha", isDirectory: true)
                .appendingPathComponent("beta", isDirectory: true)
            try? fs.createDirectory(at: deep, withIntermediateDirectories: true)
            record(assertSandboxed(deep), "Sandbox guard [I-61]: hit box fixture inside own temp directory")

            let bc = pane.uiTestBreadcrumb
            pane.uiTestEndPathEditing()
            pane.navigate(to: deep)
            try? await Task.sleep(for: .milliseconds(400))
            window.contentView?.layoutSubtreeIfNeeded()
            bc.layoutSubtreeIfNeeded()

            let h = bc.bounds.height
            let vis = bc.uiTestVisibleSegments

            // ① segment hit box fills the full height: both extreme y values at bar top and bottom must hit the segment button itself
            if let last = vis.last {
                let f = last.frame
                let kLow = bc.uiTestHitKind(at: NSPoint(x: f.midX, y: 1))
                let kHigh = bc.uiTestHitKind(at: NSPoint(x: f.midX, y: h - 1))
                // Anti-vacuous assertion: a bar never laid out or of zero height must not pass
                record(kLow == .segment && kHigh == .segment
                       && vis.count >= 2 && h >= 16
                       && f.minY == 0 && f.height == h,
                       "I-61 segment hit box fills address bar height (y=1 hit=\(kLow.rawValue) y=\(Int(h) - 1) hit=\(kHigh.rawValue) segment frame=\(f) bar height=\(h))")
            } else {
                record(false, "I-61 segment hit box fills address bar height (no visible segment)")
            }

            // ② chevron hit box fills the full height: it hugs the right of every folder name and is the biggest fall-through area (13.5/20)
            if let cf = bc.uiTestVisibleChevronFrames.last {
                let kLow = bc.uiTestHitKind(at: NSPoint(x: cf.midX, y: 1))
                let kHigh = bc.uiTestHitKind(at: NSPoint(x: cf.midX, y: h - 1))
                record(kLow == .chevron && kHigh == .chevron && cf.minY == 0 && cf.height == h,
                       "I-61 chevron hit box fills address bar height (y=1 hit=\(kLow.rawValue) y=\(Int(h) - 1) hit=\(kHigh.rawValue) chevron frame=\(cf))")
            } else {
                record(false, "I-61 chevron hit box fills address bar height (no visible chevron)")
            }

            // ③ hit margin around segment names: beyond the width math, verify the margin **really** hits this segment
            //   (the x inside the margin but outside the glyphs used to land on the previous chevron)
            if let last = vis.last, let gw = bc.uiTestLastSegmentGlyphWidth {
                let f = last.frame
                let padPoint = NSPoint(x: f.midX - gw / 2 - 2, y: h / 2)
                let kPad = bc.uiTestHitKind(at: padPoint)
                record(f.width == BreadcrumbBar.segmentHitWidth(glyphWidth: gw) && kPad == .segment,
                       "I-61 segment name keeps hit margin (hit width \(f.width) == glyphs \(gw) + \(BreadcrumbBar.uiTestSegHitPadTotal), hit inside margin=\(kPad.rawValue))")
            } else {
                record(false, "I-61 segment name keeps hit margin (cannot get segment or glyph width)")
            }

            // ④ round trip: hit at y=1, **formerly a dead zone**, and really navigate (rather than fall into typing mode)
            if vis.count >= 2 {
                let parent = vis[vis.count - 2]
                let editingBefore = pane.uiTestIsPathEditing
                let fired = bc.uiTestActivateSegment(at: NSPoint(x: parent.frame.midX, y: 1))
                try? await Task.sleep(for: .milliseconds(350))
                let landed = pane.uiTestCurrentURL.standardizedFileURL.path
                let want = parent.url.standardizedFileURL.path
                record(fired != nil && landed == want && !editingBefore && !pane.uiTestIsPathEditing,
                       "I-61 full-height hit point triggers navigation (not edit mode) (y=1 hit segment=\(fired?.lastPathComponent ?? "nil") landed=\(pane.uiTestCurrentURL.lastPathComponent) editing=\(pane.uiTestIsPathEditing))")
                pane.navigate(to: deep)
                try? await Task.sleep(for: .milliseconds(300))
                window.contentView?.layoutSubtreeIfNeeded()
                bc.layoutSubtreeIfNeeded()
            } else {
                record(false, "I-61 full-height hit point triggers navigation (not edit mode) (fewer than 2 visible segments)")
            }

            // ⑤ "click blank to edit" must survive this fix: right of the content edge is still blank, and it really enters editing
            let blank = NSPoint(x: bc.bounds.width - 4, y: h / 2)
            let kBlank = bc.uiTestHitKind(at: blank)
            let rightOK = bc.uiTestContentRight <= bc.bounds.width - 8
            pane.uiTestEndPathEditing()
            if let ev = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
                                           modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           eventNumber: 0, clickCount: 1, pressure: 1) {
                bc.mouseDown(with: ev)
            }
            try? await Task.sleep(for: .milliseconds(200))
            let entered = pane.uiTestIsPathEditing
            record(kBlank == .bar && rightOK && entered,
                   "I-61 right of the content edge is still blank and click enters editing (right edge \(Int(bc.uiTestContentRight)) bar width \(Int(bc.bounds.width)) hit=\(kBlank.rawValue) entered editing=\(entered))")
            pane.uiTestEndPathEditing()

            // ⑥ the collapse branch's "must fit" floor: squeeze the bar below the width of even the root + '…' + last segment seed;
            //   the content right edge still must not pass the bar width, and all collapsed levels stay reachable in the '…' menu.
            //   Segment width +2×segHitPadX raised this threshold; the old code would overflow outright at this width.
            let savedW = bc.frame.width
            // 48pt: the seed cost measures 104pt (root segment 16 + chevron 16 + '…' 20 + last segment 36 + chevron 16),
            // available width is only 48-16=32, which must reach the floor branch.
            // The first version used 120 → the seed just fit and removing the floor stayed green (false green, fixed).
            bc.setFrameSize(NSSize(width: 48, height: bc.frame.height))
            bc.layout()
            let narrowRight = bc.uiTestContentRight
            let narrowW = bc.frame.width
            let collapsedCount = bc.uiTestCollapsedURLs.count
            let menuCount = bc.uiTestEllipsisMenu()?.items.count ?? -1
            record(narrowW == 48 && narrowRight <= narrowW
                   && collapsedCount > 0 && menuCount == collapsedCount,
                   "I-61 very narrow bar still does not overflow and all levels are reachable (content right edge \(Int(narrowRight)) ≤ bar width \(Int(narrowW)), collapsed \(collapsedCount) menu \(menuCount))")
            bc.setFrameSize(NSSize(width: savedW, height: bc.frame.height))
            bc.layout()

            // ⑦ total width per level must match the pre-change value: the segment's horizontal hit margin was taken from the chevron slot
            //   (16→8), not added per level. Otherwise the collapse threshold shifts right 8pt per level and one fewer path level shows at the same width
            //   (review measured dualH 600 window, sidebar collapsed, 4-level path: fully shown before, collapsed after +8).
            if let last = vis.last, let cf2 = bc.uiTestVisibleChevronFrames.last,
               let gw2 = bc.uiTestLastSegmentGlyphWidth {
                let levelW = last.frame.width + cf2.width
                record(levelW == gw2 + 16 && cf2.width == 8,
                       "I-61 total width per level matches the pre-change value (segment \(last.frame.width) + chevron \(cf2.width) == glyphs \(gw2) + 16)")
            } else {
                record(false, "I-61 total width per level matches the pre-change value (cannot get segment/chevron/glyph width)")
            }

            // ⑧ clicking an inactive pane's address bar must **activate that pane**: the old version navigated without activating,
            //   leaving the window title / deck action button validation / status bar on the old pane (the list view has long reported activity via
            //   onInteract calls; only the address bar missed it).
            wc.grid.apply(layout: .dualH)
            try? await Task.sleep(for: .milliseconds(300))
            window.contentView?.layoutSubtreeIfNeeded()
            if wc.grid.visiblePanes.count >= 2 {
                let p0 = wc.grid.visiblePanes[0]
                wc.grid.setActivePane(1)
                try? await Task.sleep(for: .milliseconds(150))
                let before = wc.grid.activePaneIndex
                let bc0 = p0.uiTestBreadcrumb
                bc0.layoutSubtreeIfNeeded()
                let segs0 = bc0.uiTestVisibleSegments
                var fired: URL?
                if segs0.count >= 2 {
                    fired = bc0.uiTestActivateSegment(
                        at: NSPoint(x: segs0[segs0.count - 2].frame.midX, y: bc0.bounds.height / 2))
                }
                try? await Task.sleep(for: .milliseconds(300))
                record(before == 1 && fired != nil && wc.grid.activePaneIndex == 0,
                       "I-61 clicking an inactive pane's address bar → that pane activates (active before \(before) after \(wc.grid.activePaneIndex) hit segment=\(fired?.lastPathComponent ?? "nil"))")
            } else {
                record(false, "I-61 clicking an inactive pane's address bar → that pane activates (dual layout not applied)")
            }
            wc.grid.apply(layout: .single)
            try? await Task.sleep(for: .milliseconds(250))

            // Cleanup (token is unique, safe)
            pane.navigate(to: fs.homeDirectoryForCurrentUser)
            try? await Task.sleep(for: .milliseconds(200))
            try? fs.removeItem(at: base)
        }
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: M26 grouping scenario (list "year/month" grouping + collapse + group filter + selection kept across sorts + toggle)

    private static func runGroupingScenario(wc: MainWindowController, window: NSWindow) async {
        let fs = FileManager.default
        let cal = Calendar.current
        let token = String(UUID().uuidString.prefix(8))
        let box = fs.temporaryDirectory
            .appendingPathComponent("hspace-uitest-m26-\(token)", isDirectory: true)
        // M29 relative buckets: inject a fixed clock now=2026-06-17 12:00, fixtures land in 3 different relative buckets (2 files each, 6 in total):
        // prior years (2025-05-10) / earlier this month (2026-06-02) / today (2026-06-17). Today/yesterday/week/month/year checks all go through nowProvider
        // (see FileGrouping), so this is independent of the real system clock and deterministically assertable.
        let fixedNow = cal.date(from: DateComponents(year: 2026, month: 6, day: 17, hour: 12))!
        let priorNowProvider = FileGrouping.nowProvider
        FileGrouping.nowProvider = { fixedNow }
        // After ascending sort, group order = [prior years, this month, today]
        let bucketDates: [Date] = [
            cal.date(from: DateComponents(year: 2025, month: 5, day: 10, hour: 9))!,   // g5-2025
            cal.date(from: DateComponents(year: 2026, month: 6, day: 2, hour: 9))!,     // g3-month
            cal.date(from: DateComponents(year: 2026, month: 6, day: 17, hour: 9))!,    // g0-today
        ]
        try? fs.createDirectory(at: box, withIntermediateDirectories: true)
        var created: [URL] = []
        for (mi, date) in bucketDates.enumerated() {
            for k in 0..<2 {
                let f = box.appendingPathComponent("m26-\(token)-\(mi)-\(k).txt")
                try? Data("x".utf8).write(to: f)
                if assertSandboxed(f) {
                    try? fs.setAttributes([.modificationDate: date], ofItemAtPath: f.path)
                }
                created.append(f)
            }
        }
        let gSandbox = created.allSatisfy { assertSandboxed($0) }
        record(gSandbox, "Sandbox guard [m26]: grouping fixture of 6 files inside own fixture")

        // Preconditions: grouping on, date sort
        let hadGrouping = Preferences.listGrouping
        Preferences.listGrouping = true
        let pane = wc.grid.activePane
        pane.setViewMode(.list)
        try? await Task.sleep(for: .milliseconds(200))
        pane.navigate(to: box)
        _ = await pollFS { pane.activeTab.model.items.count == 6 }
        let listVC = pane.activeTab.listVC
        // Sort ascending by modification date (same sortDescriptors chain as the column header)
        listVC.tableView.sortDescriptors = [NSSortDescriptor(key: "dateModified", ascending: true)]
        _ = await pollFS { listVC.uiTestGroupHeaderCount == 3 }
        try? await Task.sleep(for: .milliseconds(200))

        // ① header row count == 3, titles are the relative buckets (prior years/this month/today), per-group item counts correct
        let groups = listVC.uiTestGroups
        let headerCount = listVC.uiTestGroupHeaderCount
        let expectTitles = [
            String(format: L10n.t("group.year"), 2025),
            L10n.t("group.thisMonth"),
            L10n.t("group.today"),
        ]
        let titlesOK = groups.map(\.title) == expectTitles
        let countsOK = groups.map(\.count) == [2, 2, 2]
        record(headerCount == 3 && titlesOK && countsOK && listVC.uiTestItemRowCount == 6,
               "M26 group header count == 3, relative bucket titles correct, 2 items per group (headers \(headerCount) titles \(groups.map(\.title)) expected \(expectTitles) items \(groups.map(\.count)))")
        capture(window, "31-grouping")

        // ② a group header is **a title printed on a background bar**, not a collapsible control (user request: like QSpace).
        //   Verify the real effect: clicking a header changes no row (no collapse, no selection jump to the next row), and the header itself cannot be selected.
        let firstKey = listVC.uiTestGroupKeys.first ?? ""
        let rowsBefore = listVC.uiTestRowCount
        let itemsBefore = listVC.uiTestItemRowCount
        listVC.uiTestSelectFirstItem()
        try? await Task.sleep(for: .milliseconds(120))
        let groupSelBefore = listVC.selectedURLs.map { $0.lastPathComponent }
        listVC.uiTestClickGroupRowRaw(0)        // Goes through the table view's real mouseDown branch
        try? await Task.sleep(for: .milliseconds(200))
        let groupSelAfter = listVC.selectedURLs.map { $0.lastPathComponent }
        record(listVC.uiTestRowCount == rowsBefore && listVC.uiTestItemRowCount == itemsBefore
               && listVC.uiTestGroupHeaderCount == 3 && groupSelBefore == groupSelAfter && !groupSelBefore.isEmpty
               && listVC.uiTestGroupHeaderIsBackgroundBar,
               "M26 group header is a background bar, not collapsible (rows \(rowsBefore)→\(listVC.uiTestRowCount) item rows \(itemsBefore)→\(listVC.uiTestItemRowCount) selection \(groupSelBefore)→\(groupSelAfter) has background=\(listVC.uiTestGroupHeaderIsBackgroundBar))")
        capture(window, "31b-group-bar")
        let expandedBack = listVC.uiTestItemRowCount == 6

        // ③ show only this group → the table keeps only that group's rows and the filter hint is visible; show all restores
        listVC.applyGroupFilter(key: firstKey)
        try? await Task.sleep(for: .milliseconds(200))
        let onlyOK = listVC.uiTestGroupHeaderCount == 1 && listVC.uiTestItemRowCount == 2
            && listVC.uiTestFilterPillVisible
        capture(window, "31c-filtered")
        listVC.clearGroupFilter()
        try? await Task.sleep(for: .milliseconds(200))
        let restoredOK = listVC.uiTestGroupHeaderCount == 3 && !listVC.uiTestFilterPillVisible
        record(expandedBack && onlyOK && restoredOK,
               "M26 show-only-this-group leaves that group + pill visible, show all restores (expanded back \(expandedBack) only \(onlyOK) restored \(restoredOK))")

        // ④ select an item, then re-sort across groups → selection stays by URL (I-32 semantics)
        // victim comes from "loaded real item URLs" (avoids the /var⟷/private/var symlink path mismatch; same hard rule as I-32)
        let victim = listVC.model.items.count == 6 ? listVC.model.items[2].url : (created.count > 2 ? created[2] : box)
        listVC.select(urls: [victim])
        try? await Task.sleep(for: .milliseconds(150))
        let selBefore = listVC.selectedURLs
        listVC.tableView.sortDescriptors = [NSSortDescriptor(key: "dateModified", ascending: false)]
        _ = await pollFS { listVC.uiTestGroupHeaderCount == 3 }
        try? await Task.sleep(for: .milliseconds(200))
        let selAfter = listVC.selectedURLs
        record(selBefore == [victim] && selAfter == [victim],
               "M26 selection stays by URL after cross-group re-sort (before \(selBefore.map(\.lastPathComponent)) after \(selAfter.map(\.lastPathComponent)))")

        // ④b icon view grouping (M26 v2): same fixture in icon view, section = group, collapse, filter, selection kept across rebuild
        pane.setViewMode(.icons)
        try? await Task.sleep(for: .milliseconds(300))
        if let iconVC = pane.activeTab.iconVC {
            _ = await pollFS { iconVC.uiTestSectionCount == 3 }
            let iTitles = iconVC.uiTestGroupTitles
            record(iconVC.uiTestSectionCount == 3 && Set(iTitles) == Set(expectTitles),
                   "M26v2 icon view grouping section==3 relative bucket titles correct (\(iTitles))")
            capture(window, "31d-icon-grouping")
            // Same for icon view: the group header is a background bar and does not collapse (no half-collapsible split state)
            record(iconVC.uiTestSectionCount == 3 && iconVC.uiTestGroupHeaderIsBackgroundBar
                   && !iconVC.uiTestGroupHeaderIsClickable,
                   "M26v2 icon view group header is a background bar, not collapsible (section=\(iconVC.uiTestSectionCount) has background=\(iconVC.uiTestGroupHeaderIsBackgroundBar) clickable=\(iconVC.uiTestGroupHeaderIsClickable))")
            iconVC.uiTestFilterFirstGroup()
            try? await Task.sleep(for: .milliseconds(200))
            let iFilterOK = iconVC.uiTestSectionCount == 1 && iconVC.uiTestFilterPillVisible
            iconVC.uiTestClearFilter()
            try? await Task.sleep(for: .milliseconds(200))
            let iRestore = iconVC.uiTestSectionCount == 3 && !iconVC.uiTestFilterPillVisible
            record(iFilterOK && iRestore,
                   "M26v2 icon view show-only-this-group + pill, show all restores (only \(iFilterOK) restored \(iRestore))")
            // Selection stays by URL across rebuild (grouping map does not drop selection, I-32 semantics hold in icon view)
            let ivictim = iconVC.model.items.count == 6 ? iconVC.model.items[0].url : box
            iconVC.select(urls: [ivictim])
            try? await Task.sleep(for: .milliseconds(150))
            let iSelBefore = iconVC.selectedURLs
            iconVC.uiTestClearFilter()   // Triggers one rebuild+reload
            try? await Task.sleep(for: .milliseconds(150))
            record(iSelBefore == [ivictim] && iconVC.selectedURLs == [ivictim],
                   "M26v2 icon view selection stays by URL across rebuild")
        } else {
            record(false, "M26v2 icon view grouping section==3 relative bucket titles correct")
            record(false, "M26v2 icon view collapses first group")
            record(false, "M26v2 icon view show-only-this-group + pill, show all restores")
            record(false, "M26v2 icon view selection stays by URL across rebuild")
        }
        pane.setViewMode(.list)   // Back to list for the ⑤ assertion
        try? await Task.sleep(for: .milliseconds(250))

        // ⑤ turn grouping off → header count == 0, back to a single flat list
        Preferences.listGrouping = false
        NotificationCenter.default.post(name: .hspaceGroupingChanged, object: nil)
        try? await Task.sleep(for: .milliseconds(250))
        record(listVC.uiTestGroupHeaderCount == 0 && listVC.uiTestRowCount == 6 && !listVC.uiTestGroupingActive,
               "M26 grouping off: header count == 0, back to flat list (headers \(listVC.uiTestGroupHeaderCount) rows \(listVC.uiTestRowCount))")

        // Wrap up: restore preference/sort/clock, clear the fixture
        Preferences.listGrouping = hadGrouping
        FileGrouping.nowProvider = priorNowProvider
        NotificationCenter.default.post(name: .hspaceGroupingChanged, object: nil)
        listVC.tableView.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        listVC.select(urls: [])
        pane.navigate(to: fs.homeDirectoryForCurrentUser)
        try? await Task.sleep(for: .milliseconds(200))
        if assertSandboxed(box) { try? fs.removeItem(at: box) }
        window.makeKeyAndOrderFront(nil)
    }

    /// M29 relative time pure logic: with fixed clock now=2026-06-17, 6 bucket keyTitle placement + date column relative format
    /// (today/yesterday prefixed, year hidden this year, shown only for other years). Deterministic pure-function check, no file system or UI.
    private static func runRelativeTimeUnit() {
        let cal = Calendar.current
        guard let now = cal.date(from: DateComponents(year: 2026, month: 6, day: 17, hour: 12)) else {
            record(false, "M29 relative buckets: 6 bucket keyTitle placement correct"); record(false, "M29 date column hides year this year, shows it otherwise"); return
        }
        let prior = FileGrouping.nowProvider
        FileGrouping.nowProvider = { now }
        defer { FileGrouping.nowProvider = prior }

        func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
            cal.date(from: DateComponents(year: y, month: m, day: d, hour: 9))!
        }
        func item(_ dt: Date) -> FileItem {
            FileItem(url: URL(fileURLWithPath: "/tmp/hspace-m29-\(dt.timeIntervalSinceReferenceDate)"),
                     name: "x", isDirectory: false, isPackage: false, isSymlink: false,
                     isHidden: false, size: 0, modified: dt, created: dt, added: dt, contentTypeID: nil)
        }
        // 6 buckets: today/yesterday/this week/earlier this month/earlier this year/prior years
        let cases: [(Date, String)] = [
            (date(2026, 6, 17), "g0-today"),        // same day
            (date(2026, 6, 16), "g1-yesterday"),    // now-1d
            (date(2026, 6, 15), "g2-week"),         // same week, not today or yesterday (Mon/Tue/Wed in one week, stable across locales)
            (date(2026, 6, 2),  "g3-month"),        // same month, not this week
            (date(2026, 2, 10), "g4-year-earlier"), // same year, not this month
            (date(2025, 5, 10), "g5-2025"),         // prior years, by year
        ]
        let keys = cases.map { FileGrouping.keyTitle(for: item($0.0), key: .dateModified).key }
        let expected = cases.map { $0.1 }
        record(keys == expected, "M29 relative buckets: 6 bucket keyTitle placement correct (got \(keys) expected \(expected))")

        // Date column relative format (Formatters.relativeDate, now injected explicitly)
        let today = Formatters.relativeDate(date(2026, 6, 17), now: now)
        let yst = Formatters.relativeDate(date(2026, 6, 16), now: now)
        let thisYear = Formatters.relativeDate(date(2026, 2, 10), now: now)   // This year → no "2026"
        let otherYear = Formatters.relativeDate(date(2025, 5, 10), now: now)  // Prior year → has "2025"
        let todayOK = today.hasPrefix(L10n.t("date.today"))
        let ystOK = yst.hasPrefix(L10n.t("date.yesterday"))
        let thisYearNoYear = !thisYear.contains("2026")     // Year hidden this year (the core the user named)
        let otherYearHasYear = otherYear.contains("2025")   // Year shown for other years
        record(todayOK && ystOK && thisYearNoYear && otherYearHasYear,
               "M29 date column hides year this year, shows it otherwise (today \(today) yesterday \(yst) this year \(thisYear) prior \(otherYear))")

        // I-49: when foldersFirst scrambles first-appearance order, groups still sort by relative recency (today newest → first).
        // Simulated items=[folders desc][files desc]: folders on yesterday/this week, files on today. The old "first appearance" logic pushed
        // the files-only "today" bucket behind the folder-established order (user report: "today is at the very bottom"). New logic sorts by recencyRank, today first.
        func dirItem(_ dt: Date) -> FileItem {
            FileItem(url: URL(fileURLWithPath: "/tmp/hspace-i49-\(dt.timeIntervalSinceReferenceDate)"),
                     name: "d", isDirectory: true, isPackage: false, isSymlink: false,
                     isHidden: false, size: nil, modified: dt, created: dt, added: dt, contentTypeID: nil)
        }
        let scrambled = [dirItem(date(2026, 6, 16)), dirItem(date(2026, 6, 15)), item(date(2026, 6, 17))]
        let gsDesc = FileGrouping.buckets(scrambled, key: .dateModified, ascending: false).map(\.key)
        record(gsDesc.first == "g0-today",
               "I-49 foldersFirst groups still sort by recency: today (files only) is first, not pushed to the end by folder buckets (got \(gsDesc))")
    }

    /// I-44: third-party "open file location" (Antigravity etc via activateFileViewerSelectingURLs → openFileURLs →
    /// openWindow(selecting:)) used to drop the select argument entirely, reaching the parent without selecting the file. Verifies:
    /// ① openWindow(selecting:) really selects the target in list view; ② pane.reveal really selects in icon view too (not listVC).
    /// Sandbox hard rule: touch only self-created hspace-uitest-reveal-* fixtures.
    private static func runRevealSelectScenario(delegate: AppDelegate) async {
        let fs = FileManager.default
        let token = String(UUID().uuidString.prefix(8))
        let box = fs.temporaryDirectory
            .appendingPathComponent("hspace-uitest-reveal-\(token)", isDirectory: true)
        try? fs.createDirectory(at: box, withIntermediateDirectories: true)
        var files: [URL] = []
        for i in 0..<4 {
            let f = box.appendingPathComponent("reveal-\(token)-\(i).txt")
            try? Data("x".utf8).write(to: f)
            files.append(f)
        }
        let target = files[2]
        record(files.allSatisfy { assertSandboxed($0) }, "Sandbox guard [I-44]: reveal fixture of 4 files inside own fixture")

        // ① simulate the default landing of a third-party "open file location" (externalOpenTarget=newTab → openWindow(selecting:)).
        // The select argument used to be dropped entirely; this verifies it is wired up and selects in the default view (independent of view mode and the user's default view)
        let wc = delegate.openWindow(at: box, selecting: target)
        let pane = wc.grid.activePane
        _ = await pollFS { pane.activeTab.model.items.count == 4 }
        _ = await pollFS { pane.currentSelectionCount == 1 }
        record(pane.currentSelectionCount == 1,
               "I-44 openWindow(selecting:) really locates and selects the target file (select argument no longer dropped, selected=\(pane.currentSelectionCount))")
        if let w = wc.window { capture(w, "32-reveal") }

        // ② list view reveal dispatch: navigate triggers the async load + pending selection lands
        pane.setViewMode(.list)
        try? await Task.sleep(for: .milliseconds(200))
        pane.navigate(to: box)
        pane.reveal(target)
        _ = await pollFS { pane.activeTab.listVC.selectedURLs.count == 1 }
        let selList = pane.activeTab.listVC.selectedURLs.map(\.standardizedFileURL)
        record(selList == [target.standardizedFileURL],
               "I-44 list view reveal really locates and selects the target file (\(selList.map(\.lastPathComponent)))")

        // I-48: after reveal the table becomes first responder → selection shows blue accent (otherwise the unemphasized gray is nearly invisible; user report: "no blue selection")
        let fr = wc.window?.firstResponder
        record(fr === pane.activeTab.listVC.tableView,
               "I-48 reveal focuses the table (selection shows blue accent, not unemphasized gray) (firstResponder=\(type(of: fr as Any)))")

        // I-45: QL dismiss fades (sourceFrame in dismiss state = .zero, QL no longer "shrinks to the icon"); open state = inline icon rect (zoom kept)
        let lvc = pane.activeTab.listVC
        let qlFade = lvc.uiTestQLSourceFrame(dismissing: true, for: target)
        let qlZoom = lvc.uiTestQLSourceFrame(dismissing: false, for: target)
        record(qlFade == .zero && qlZoom != .zero,
               "I-45 QL dismiss sourceFrame fades (.zero), open zooms from icon rect (dismiss \(NSStringFromRect(qlFade)) open \(NSStringFromRect(qlZoom)))")

        // ③ icon view reveal (via the iconVC branch, not a hardcoded listVC): same navigate + pending landing
        pane.setViewMode(.icons)
        try? await Task.sleep(for: .milliseconds(250))
        pane.navigate(to: box)
        pane.reveal(target)
        _ = await pollFS { (pane.activeTab.iconVC?.selectedURLs.count ?? 0) == 1 }
        let selIcon = (pane.activeTab.iconVC?.selectedURLs ?? []).map(\.standardizedFileURL)
        record(selIcon == [target.standardizedFileURL],
               "I-44 icon view reveal really locates and selects the target file (view-mode aware, not a hardcoded listVC) (\(selIcon.map(\.lastPathComponent)))")

        // Wrap up: close the test window + clear the fixture
        wc.window?.orderOut(nil)
        wc.window?.close()
        try? await Task.sleep(for: .milliseconds(150))
        if assertSandboxed(box) { try? fs.removeItem(at: box) }
    }

    /// M28: smart search ranking integration: two same-named hits (equal match quality) differ only in frecency, verifying:
    /// toggle on → high frecency first (blended score takes over); toggle off → back to arrival order (frecency stays out).
    /// Through the real appendResults/rankLess chain (uiTestAppend), deterministic, touching neither the real engine nor user files.
    private static func runSmartSortScenario() {
        let sp = SearchPanelController.shared
        let base = URL(fileURLWithPath: "/tmp/hspace-m28-\(UUID().uuidString.prefix(6))")
        let a = base.appendingPathComponent("A/note.txt")
        let b = base.appendingPathComponent("B/note.txt")
        func hit(_ u: URL) -> SearchHit {
            SearchHit(url: u, name: "note.txt", isDirectory: false, size: 1, modified: nil,
                      contentTypeID: "public.plain-text")
        }
        let snapshot = [b.standardizedFileURL.path: FrecencyEntry(count: 12, lastAccess: Date())]

        // Smart on: B (high frecency) ranks before A (equal match quality → frecency alone decides)
        sp.uiTestReset(root: nil)
        sp.uiTestConfigureSmart(query: "note", snapshot: snapshot, active: true)
        sp.uiTestAppend([hit(a), hit(b)])
        let onFirst = sp.uiTestResultPaths.first
        record(onFirst == b.path,
               "M28 smart sort on: high frecency hit ranks first (first=\((onFirst.map { ($0 as NSString).lastPathComponent }) ?? "nil"), expected B/note.txt)")

        // Smart off: back to arrival order (A appended first → A leads, unaffected by frecency)
        sp.uiTestReset(root: nil)
        sp.uiTestConfigureSmart(query: "note", snapshot: snapshot, active: false)
        sp.uiTestAppend([hit(a), hit(b)])
        let offFirst = sp.uiTestResultPaths.first
        record(offFirst == a.path,
               "M28 smart sort off: back to arrival order (first=\((offFirst.map { ($0 as NSString).lastPathComponent }) ?? "nil"), expected A/note.txt)")

        // ── I-74: hits matching the query's case rank first (user report: "show matching case first,
        // then the ones with the same characters but different case") ──
        // Injected through uiTestAppend, not real files: APFS is case-insensitive by default,
        // `override.md` and `OVERRIDE.md` are one file in one directory, so the contrast cannot be built on disk.
        let lower = base.appendingPathComponent("C/nsoverride.md")
        let upper = base.appendingPathComponent("D/NSOVERRIDE.md")
        func mdHit(_ u: URL) -> SearchHit {
            SearchHit(url: u, name: u.lastPathComponent, isDirectory: false, size: 1,
                      modified: nil, contentTypeID: "net.daringfireball.markdown")
        }
        sp.uiTestReset(root: nil)
        sp.uiTestConfigureSmart(query: "nsoverride", snapshot: [:], active: true)
        // Append the uppercase one first: if the comparator had no effect, arrival order would keep it first and the assertion goes red
        sp.uiTestAppend([mdHit(upper), mdHit(lower)])
        let caseFirst = sp.uiTestResultPaths.first
        record(caseFirst == lower.path,
               "I-74 hits matching the query's case rank first (first=\((caseFirst.map { ($0 as NSString).lastPathComponent }) ?? "nil"), expected nsoverride.md)")

        // Queries with spaces must also score and rank at the panel layer (engine finds them, ranking scores 0 and sinks them = the user still does not see them)
        sp.uiTestReset(root: nil)
        sp.uiTestConfigureSmart(query: "nsoverride md", snapshot: [:], active: true)
        sp.uiTestAppend([mdHit(upper), mdHit(lower)])
        let spacedFirst = sp.uiTestResultPaths.first
        record(sp.uiTestResultPaths.count == 2 && spacedFirst == lower.path,
               "I-74 query with spaces works in result ranking too (\(sp.uiTestResultPaths.count) hits, first=\((spacedFirst.map { ($0 as NSString).lastPathComponent }) ?? "nil"))")
        sp.uiTestReset(root: nil)
    }

    /// I-47: navigation persists immediately: after navigating the active pane to a fixture, the session (isolated storage) should remember that directory within the debounce.
    /// Proves onActiveLocationChange→noteStateChanged works: location is no longer saved only on clean exit, and an unclean exit does not return to home.
    private static func runSessionSaveScenario(delegate: AppDelegate) async {
        let fs = FileManager.default
        let token = String(UUID().uuidString.prefix(8))
        let box = fs.temporaryDirectory.appendingPathComponent("hspace-uitest-sess-\(token)", isDirectory: true)
        try? fs.createDirectory(at: box, withIntermediateDirectories: true)
        record(assertSandboxed(box), "Sandbox guard [I-47]: session fixture inside own fixture")
        guard let wc = NSApp.windows.compactMap({ $0.windowController as? MainWindowController }).first else {
            record(false, "I-47 navigation persists immediately: session remembers the navigated directory"); return
        }
        let pane = wc.grid.activePane
        pane.navigate(to: box)   // → onActiveLocationChange → noteStateChanged (sessionReady=true under UITEST)
        // Poll rather than a fixed sleep: SessionStore debounces 1s, and the old 1400ms left only 400ms of margin;
        // a longer suite or busier machine gave false failures (reproduced 1 in 6). Polling is also faster in the common case.
        var hit = false
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(100))
            let snap = await delegate.sessionStore.load()
            let paths = (snap?.windows ?? [])
                .flatMap { $0.workspaces }.flatMap { $0.panes }.map { $0.tab.path }
            if paths.contains(box.path) || paths.contains(box.standardizedFileURL.path) { hit = true; break }
        }
        record(hit, "I-47 navigation persists immediately: session remembers the navigated directory (isolated session has \(box.lastPathComponent)=\(hit))")

        // I-50: sort changes persist immediately (changing sort by header click used to trigger no save; an unclean exit restarted with the old sort)
        pane.setViewMode(.list)
        try? await Task.sleep(for: .milliseconds(150))
        pane.activeTab.listVC.tableView.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)]
        // Same as above: poll until persisted, no betting on the debounce window with a fixed sleep
        var lastKey: String?
        var lastAsc: Bool?
        var sortSaved = false
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(100))
            let snap2 = await delegate.sessionStore.load()
            let tab = (snap2?.windows ?? [])
                .flatMap { $0.workspaces }.flatMap { $0.panes }.map { $0.tab }
                .first { $0.path == box.path || $0.path == box.standardizedFileURL.path }
            lastKey = tab?.sortKey
            lastAsc = tab?.sortAscending
            if lastKey == "size" && lastAsc == false { sortSaved = true; break }
        }
        record(sortSaved, "I-50 sort change persists immediately: session remembers sort column/direction (got \(lastKey ?? "nil")/\(lastAsc.map { String($0) } ?? "nil"), expected size/false)")

        // Wrap up: navigate back home + clear the fixture
        pane.navigate(to: fs.homeDirectoryForCurrentUser)
        try? await Task.sleep(for: .milliseconds(200))
        if assertSandboxed(box) { try? fs.removeItem(at: box) }
    }

    /// I-52: configurable landing spot for external/browser reveal: the default "new tab in existing window" reuses the current window (no new window,
    /// fixing the user-reported "opens a new window every time"); only "New Window" opens one each time. Verified through the real application(_:open:) → openFileURLs chain.
    private static func runExternalOpenTargetScenario(delegate: AppDelegate) async {
        let fs = FileManager.default
        let token = String(UUID().uuidString.prefix(8))
        let box = fs.temporaryDirectory.appendingPathComponent("hspace-uitest-extopen-\(token)", isDirectory: true)
        try? fs.createDirectory(at: box, withIntermediateDirectories: true)
        record(assertSandboxed(box), "Sandbox guard [I-52]: external open fixture inside own fixture")
        func mainWins() -> Int { NSApp.windows.filter { $0.windowController is MainWindowController && $0.isVisible }.count }
        guard let wc = NSApp.windows.compactMap({ $0.windowController as? MainWindowController }).first,
              let hostWindow = wc.window else {
            record(false, "I-52 external open defaults to a new tab: reuses the existing window, no new window"); return
        }
        let prev = Preferences.externalOpenTarget

        // Settle precondition: external opens route to the [key window]; first make the host window key and wait for windows left by earlier scenarios to close,
        // or the assertion checks the first window while the open lands on a leftover key window, a timing false failure of "tab not +1" (exposed by I-53's added time).
        hostWindow.makeKeyAndOrderFront(nil)
        _ = await pollFS { mainWins() == 1 }
        try? await Task.sleep(for: .milliseconds(100))

        // Default "new workspace tab in existing window": window count unchanged, workspaces +1, active pane lands on the target directory.
        // Since v0.19.26 the landing moved from pane tabs to workspace tabs (in-pane tabs retired); the path dimension is new:
        // counting "workspaces +1" alone cannot tell **where** it opened, and a wrong directory is the likeliest failure of this change.
        Preferences.externalOpenTarget = "newTab"
        let w0 = mainWins(); let ws0 = wc.workspaceCount
        delegate.application(NSApp, open: [box])
        _ = await pollFS { wc.workspaceCount == ws0 + 1 }
        let landed = await pollFS { samePath(wc.grid.activePane.uiTestCurrentURL, box) }
        record(mainWins() == w0 && wc.workspaceCount == ws0 + 1 && landed,
               "I-52 external open defaults to a 'new workspace tab': reuses the existing window, no new window (windows \(w0)→\(mainWins()), workspaces \(ws0)→\(wc.workspaceCount), reached target directory=\(landed))")

        // "New Window": window count +1
        Preferences.externalOpenTarget = "newWindow"
        let w1 = mainWins()
        delegate.application(NSApp, open: [box])
        _ = await pollFS { mainWins() == w1 + 1 }
        record(mainWins() == w1 + 1, "I-52 external open 'New Window': opens a new window (windows \(w1)→\(mainWins()))")
        for w in NSApp.windows where (w.windowController is MainWindowController) && w !== hostWindow { w.close() }
        hostWindow.makeKeyAndOrderFront(nil)
        while wc.workspaceCount > ws0 { wc.closeActiveWorkspace(nil) }
        try? await Task.sleep(for: .milliseconds(200))

        // ── I-73: external open must not trample other panes / must not evict the user's workspaces / same-directory files open only one ──
        // All three are new risks from "landing moved from pane tabs to workspace tabs" (caught in adversarial review):
        // a workspace tab is much heavier than a pane tab: it copies the whole layout, and a slip rebuilds other panes along with their
        // browsing history/selection/scroll position, or the limit squeezes out the user's oldest workspace.
        Preferences.externalOpenTarget = "newTab"
        let f1 = box.appendingPathComponent("i73-a.txt")
        let f2 = box.appendingPathComponent("i73-b.txt")
        try? Data("a".utf8).write(to: f1)
        try? Data("b".utf8).write(to: f2)

        // ① an inactive pane's selection must survive (dual panes: select a file in the right pane, then open externally into the left)
        let layout0 = wc.grid.layout
        wc.grid.apply(layout: .dualH)
        try? await Task.sleep(for: .milliseconds(300))
        let other = wc.grid.visiblePanes.count > 1 ? wc.grid.visiblePanes[1] : nil
        var otherKept = false
        var otherSelBefore: [URL] = []
        if let other {
            other.setViewMode(.list)
            other.navigate(to: box)
            _ = await pollFS { other.activeTab.model.items.count >= 2 }
            other.activeTab.listVC.select(urls: [f1])
            try? await Task.sleep(for: .milliseconds(200))
            otherSelBefore = other.activeTab.listVC.selectedURLs
            wc.grid.setActivePane(0)
            try? await Task.sleep(for: .milliseconds(150))
            delegate.application(NSApp, open: [box])
            _ = await pollFS { wc.workspaceCount > ws0 }
            try? await Task.sleep(for: .milliseconds(400))
            // Same pane object still there and selection not cleared: proves it was not rebuilt
            let now = wc.grid.visiblePanes.count > 1 ? wc.grid.visiblePanes[1] : nil
            otherKept = now === other && !otherSelBefore.isEmpty
                && now?.activeTab.listVC.selectedURLs.map(\.path) == otherSelBefore.map(\.path)
        }
        record(otherKept,
               "I-73 external open does not rebuild other panes: inactive pane selection kept (selected \(otherSelBefore.count) items, kept=\(otherKept))")
        while wc.workspaceCount > ws0 { wc.closeActiveWorkspace(nil) }
        wc.grid.apply(layout: layout0)
        try? await Task.sleep(for: .milliseconds(250))

        // ② multiple files from one directory open only **one** workspace (revealing five attachments at once should not explode into five)
        // This is also the only coverage of the everyday **external open of a "file"** path (I-52/I-60 open directories only):
        // with a file, it must land on the parent directory with that file selected;
        // "Show in Finder" means "point it out for me", and stopping at the directory leaves the job unfinished.
        let wsMerge0 = wc.workspaceCount
        delegate.application(NSApp, open: [f1, f2])
        _ = await pollFS { wc.workspaceCount == wsMerge0 + 1 }
        let revealed = await pollFS {
            samePath(wc.grid.activePane.uiTestCurrentURL, box)
                && wc.grid.activePane.activeTab.listVC.selectedURLs.contains { samePath($0, f1) }
        }
        let merged = wc.workspaceCount == wsMerge0 + 1
        record(merged && revealed,
               "I-73 same-directory multi-file external open opens one workspace and selects the target file (workspaces \(wsMerge0)→\(wc.workspaceCount), sent 2 files from one directory, landed + selected=\(revealed))")
        while wc.workspaceCount > ws0 { wc.closeActiveWorkspace(nil) }
        try? await Task.sleep(for: .milliseconds(200))

        // ③ at the workspace limit, external open must not evict the oldest (an action triggered by another app must not destroy user state)
        let limit0 = Preferences.workspaceTabLimit
        let wsBase = wc.workspaceCount
        Preferences.workspaceTabLimit = wsBase + 1
        wc.openWorkspaceTab(at: nil)                       // Fill up to the limit as an explicit ⌘T would
        try? await Task.sleep(for: .milliseconds(300))
        let atLimit = wc.workspaceCount
        let oldestBefore = wc.uiTestWorkspaceTitles.first
        delegate.application(NSApp, open: [box])
        try? await Task.sleep(for: .milliseconds(600))
        let oldestAfter = wc.uiTestWorkspaceTitles.first
        let noEvict = wc.workspaceCount == atLimit && oldestBefore != nil && oldestAfter == oldestBefore
        record(noEvict,
               "I-73 at the workspace limit external open does not evict the oldest (limit \(Preferences.workspaceTabLimit) workspaces \(atLimit)→\(wc.workspaceCount) oldest \(oldestBefore ?? "nil")→\(oldestAfter ?? "nil"))")
        Preferences.workspaceTabLimit = limit0

        // Wrap up: restore preferences + close extra windows (keep the host window) + close workspaces this scenario added + clear the fixture
        Preferences.externalOpenTarget = prev
        for w in NSApp.windows where (w.windowController is MainWindowController) && w !== hostWindow { w.close() }
        while wc.workspaceCount > ws0 { wc.closeActiveWorkspace(nil) }
        hostWindow.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(200))
        if assertSandboxed(box) { try? fs.removeItem(at: box) }
    }

    // MARK: Utilities

    private static func record(_ ok: Bool, _ message: String) {
        lines.append("\(ok ? "PASS" : "FAIL") \(message)")
        if !ok { failed = true }
        // Persist progress in real time (a hang can be traced to the last point reached; before finish, records lived only in memory and a hang lost them all; instrument added after I-35)
        try? (lines.joined(separator: "\n") + "\n").data(using: .utf8)?
            .write(to: outDir.appendingPathComponent("progress.txt"))
    }

    /// Self-rendered screenshot: no Screen Recording permission needed
    private static func capture(_ window: NSWindow, _ name: String) {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: outDir.appendingPathComponent("\(name).png"))
    }

    /// Screenshot any view (need not be in a visible window; for headless human review of custom-drawn sheet content)
    private static func captureView(_ view: NSView, _ name: String) {
        view.layoutSubtreeIfNeeded()
        guard view.bounds.width > 0, view.bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: outDir.appendingPathComponent("\(name).png"))
    }

    private static func viewTree(_ root: NSView?) -> [NSView] {
        guard let root else { return [] }
        return [root] + root.subviews.flatMap { viewTree($0) }
    }

    /// File system result polling (coordinator/kernel operations persist asynchronously): returns once the condition holds, on timeout returns the last evaluation
    private static func pollFS(_ tries: Int = 30, _ cond: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<tries {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return cond()
    }

    /// Path equivalence (resolves the /var⟷/private/var symlink difference)
    private static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().standardizedFileURL.path
            == b.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Send one **real** Return key to the address bar field editor (keyDown → responder chain → doCommandBy
    /// insertNewline; calling the callback directly is a shortcut that misses broken key routing)
    private static func pressReturn(in editor: PathEditorField, window: NSWindow) {
        guard let fe = editor.currentEditor() as? NSTextView,
              let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil,
                                        characters: "\r", charactersIgnoringModifiers: "\r",
                                        isARepeat: false, keyCode: 36)
        else { return }
        fe.keyDown(with: ev)
    }

    /// Sandbox guard (user's hard rule 2026-08-26): the target of any mutating test file operation must be inside a self-made temp fixture
    /// (under temporaryDirectory), to protect the user's real files. On guard failure the mutating operation is skipped.
    private static func assertSandboxed(_ url: URL) -> Bool {
        let sandboxRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        return url.resolvingSymlinksInPath().path.hasPrefix(sandboxRoot)
    }

    static var extraDump: [String] = []

    private static func finish() {
        if !extraDump.isEmpty {
            try? extraDump.joined(separator: "\n\n").data(using: .utf8)?
                .write(to: outDir.appendingPathComponent("resize-stacks.txt"))
        }
        let report = lines.joined(separator: "\n") + "\n"
        try? report.data(using: .utf8)?.write(to: outDir.appendingPathComponent("report.txt"))
        exit(failed ? 1 : 0)
    }
}

#else

/// Release builds carry no self-test, only the one flag product code asks about.
enum UISelfTest {
    static var isEnabled: Bool { false }
}

#endif
