import AppKit

/// Settings window (⌘,) with three tabs: General (externalized defaults) / Shortcuts (registry, recordable) / Finder Replacement.
/// Principle: all configurable items live here (externalized through Preferences/KeyBindings, with no scattered hard-coding).
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = L10n.t("settings.title")
        window.center()
        super.init(window: window)
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    private let searchField = NSSearchField()
    private let resultsTable = NSTableView()
    private let resultsScroll = NSScrollView()
    private var resultsHeight: NSLayoutConstraint!
    private weak var tabsRef: NSTabView?
    private var searchIndex: [SettingsSearch.Hit] = []
    private var hits: [SettingsSearch.Hit] = []

    override func showWindow(_ sender: Any?) {
        refreshFinderState()
        refreshRevealState()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildUI() {
        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false

        let general = NSTabViewItem(identifier: "general")
        general.label = L10n.t("settings.tab.general")
        general.view = buildGeneralTab()
        tabs.addTabViewItem(general)

        let keys = NSTabViewItem(identifier: "keys")
        keys.label = L10n.t("settings.tab.shortcuts")
        keys.view = buildShortcutsTab()
        tabs.addTabViewItem(keys)

        for (i, page) in SettingsPages.extraPages.enumerated() {
            let item = NSTabViewItem(identifier: "extra\(i)")
            item.label = L10n.t(page.pageTitleKey)
            item.view = page.makeView()
            tabs.addTabViewItem(item)
        }

        let finder = NSTabViewItem(identifier: "finder")
        finder.label = L10n.t("settings.finderSection")
        finder.view = buildFinderTab()
        tabs.addTabViewItem(finder)

        // Settings search at the top: the index is read live from the **assembled view tree**, so it always equals the UI itself
        tabsRef = tabs
        searchField.placeholderString = L10n.t("settings.search.placeholder")
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false

        resultsTable.headerView = nil
        resultsTable.rowHeight = 22
        resultsTable.style = .inset
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("hit"))
        col.resizingMask = .autoresizingMask
        resultsTable.addTableColumn(col)
        resultsTable.dataSource = self
        resultsTable.delegate = self
        resultsTable.target = self
        resultsTable.action = #selector(resultClicked(_:))
        resultsScroll.documentView = resultsTable
        resultsScroll.hasVerticalScroller = true
        resultsScroll.borderType = .bezelBorder
        resultsScroll.translatesAutoresizingMaskIntoConstraints = false
        resultsScroll.isHidden = true

        let content = NSView()
        content.addSubview(searchField)
        content.addSubview(tabs)
        content.addSubview(resultsScroll)
        resultsHeight = resultsScroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),

            resultsScroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 4),
            resultsScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            resultsScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            resultsHeight,

            tabs.topAnchor.constraint(equalTo: resultsScroll.bottomAnchor, constant: 8),
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            tabs.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        window?.contentView = content
        // Build the index once after assembly (each page's makeView has run, so the view tree is complete)
        searchIndex = SettingsSearch.index(tabs)
    }

    // MARK: Settings search

    @objc private func searchChanged(_ sender: Any?) {
        applySearch(searchField.stringValue)
    }

    /// internal: driven directly by self-tests, without synthesizing keyboard events
    func applySearch(_ query: String) {
        hits = SettingsSearch.matches(query, in: searchIndex)
        resultsTable.reloadData()
        let show = !hits.isEmpty
        resultsScroll.isHidden = !show
        // Height follows the row count, up to 6 rows; 0 = collapsed (a hidden view still occupies its Auto Layout slot)
        resultsHeight.constant = show ? CGFloat(min(hits.count, 6)) * resultsTable.rowHeight + 4 : 0
    }

    @objc private func resultClicked(_ sender: Any?) {
        let row = resultsTable.clickedRow >= 0 ? resultsTable.clickedRow : resultsTable.selectedRow
        jumpToResult(row)
    }

    /// internal: driven directly by self-tests (switch page + scroll into view + flash highlight)
    @discardableResult
    func jumpToResult(_ row: Int) -> Bool {
        guard hits.indices.contains(row), let tabs = tabsRef else { return false }
        SettingsSearch.reveal(hits[row], in: tabs)
        return true
    }

    // ---- Self-test channel (I-65) ----
    var uiTestSearchIndexCount: Int { searchIndex.count }
    var uiTestSearchResultCount: Int { hits.count }
    var uiTestSearchResultsVisible: Bool { !resultsScroll.isHidden }
    var uiTestSelectedTabIndex: Int {
        guard let tabs = tabsRef, let sel = tabs.selectedTabViewItem else { return -1 }
        return tabs.indexOfTabViewItem(sel)
    }
    var uiTestSearchIndexTexts: [String] { searchIndex.map(\.text) }
    /// Self-test page switch (a jump assertion must switch to another page first, else being on that page already passes vacuously)
    func uiTestSelectTab(_ i: Int) {
        guard let tabs = tabsRef, tabs.tabViewItems.indices.contains(i) else { return }
        tabs.selectTabViewItem(at: i)
    }
    func uiTestSearchResultTabIndex(_ row: Int) -> Int {
        hits.indices.contains(row) ? hits[row].tabIndex : -1
    }

    // MARK: General page (exposes all externalized Preferences items)

    private func popupRow(_ titleKey: String, options: [(tag: Int, title: String)],
                          selectedTag: Int, action: Selector) -> NSView {
        let label = NSTextField(labelWithString: L10n.t(titleKey))
        label.font = .systemFont(ofSize: 12)
        let popup = NSPopUpButton()
        for o in options {
            popup.addItem(withTitle: o.title)
            popup.lastItem?.tag = o.tag
        }
        popup.selectItem(withTag: selectedTag)
        popup.target = self
        popup.action = action
        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.spacing = 8
        label.widthAnchor.constraint(equalToConstant: 152).isActive = true
        return row
    }

    private func checkRow(_ titleKey: String, checked: Bool, action: Selector) -> NSButton {
        let b = NSButton(checkboxWithTitle: L10n.t(titleKey), target: self, action: action)
        b.state = checked ? .on : .off
        b.font = .systemFont(ofSize: 12)
        return b
    }

    private func buildGeneralTab() -> NSView {
        let layoutRow = popupRow("settings.defaultLayout",
            options: PaneLayout.allCases.map { ($0.rawValue, $0.localizedName) },
            selectedTag: Preferences.defaultLayoutRaw,
            action: #selector(defaultLayoutChanged(_:)))
        let viewRow = popupRow("settings.defaultView",
            options: [(0, L10n.t("menu.viewAsIcons")), (1, L10n.t("menu.viewAsList")), (2, L10n.t("menu.viewAsColumns"))],
            selectedTag: Preferences.defaultViewModeRaw,
            action: #selector(defaultViewChanged(_:)))
        let termRow = popupRow("settings.terminal",
            options: Preferences.terminalOptions.enumerated().map { ($0.offset, L10n.t($0.element.nameKey)) },
            selectedTag: Preferences.terminalOptions.firstIndex { $0.id == Preferences.terminalChoice } ?? 0,
            action: #selector(terminalChanged(_:)))

        let hidden = checkRow("settings.showHidden", checked: Preferences.showHiddenByDefault,
                              action: #selector(showHiddenChanged(_:)))
        let folders = checkRow("settings.foldersFirst", checked: Preferences.foldersFirst,
                               action: #selector(foldersFirstChanged(_:)))

        let note = NSTextField(wrappingLabelWithString: L10n.t("settings.applyNote"))
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor

        // I-14: default bookmark seeds can be deleted and restored; the restore button refills missing seeds (dedupes by path, leaves user bookmarks alone)
        let restoreSeeds = NSButton(title: L10n.t("settings.restoreSeeds"), target: self,
                                    action: #selector(restoreDefaultSeeds))
        restoreSeeds.bezelStyle = .push

        // M24: global show/hide hotkey (Carbon, no Accessibility permission needed; replaces the Raycast bridge)
        let hotkeyLabel = NSTextField(labelWithString: L10n.t("settings.globalHotkey"))
        hotkeyLabel.font = .systemFont(ofSize: 12)
        hotkeyLabel.widthAnchor.constraint(equalToConstant: 152).isActive = true
        let hotkeyRecorder = GlobalHotkeyRecorderButton()
        let hotkeyRow = NSStackView(views: [hotkeyLabel, hotkeyRecorder])
        hotkeyRow.orientation = .horizontal
        hotkeyRow.spacing = 8
        let hotkeyNote = NSTextField(wrappingLabelWithString: L10n.t("settings.globalHotkey.note"))
        hotkeyNote.font = .systemFont(ofSize: 11)
        hotkeyNote.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [layoutRow, viewRow, termRow,
                                        NSBox.separatorLine(), hidden, folders,
                                        NSBox.separatorLine(), hotkeyRow, hotkeyNote,
                                        NSBox.separatorLine(), restoreSeeds,
                                        NSBox.separatorLine(),
                                        NSBox.separatorLine(), note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        return wrap(stack)
    }

    @objc private func defaultLayoutChanged(_ sender: NSPopUpButton) {
        Preferences.defaultLayoutRaw = sender.selectedTag()
    }

    @objc private func defaultViewChanged(_ sender: NSPopUpButton) {
        Preferences.defaultViewModeRaw = sender.selectedTag()
    }

    @objc private func terminalChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        guard Preferences.terminalOptions.indices.contains(idx) else { return }
        Preferences.terminalChoice = Preferences.terminalOptions[idx].id
    }

    @objc private func showHiddenChanged(_ sender: NSButton) {
        Preferences.showHiddenByDefault = sender.state == .on
    }

    @objc private func foldersFirstChanged(_ sender: NSButton) {
        Preferences.foldersFirst = sender.state == .on
    }

    @objc private func restoreDefaultSeeds() {
        let wcs = NSApp.windows.compactMap { $0.windowController as? MainWindowController }
        guard let first = wcs.first else { return }
        Task { @MainActor in
            let added = await first.sidebar.model.restoreDefaultSeeds()
            for wc in wcs.dropFirst() { wc.sidebar.model.rebuild() }
            Toast.show(String(format: L10n.t("toast.seedsRestored"), added), in: first.window)
        }
    }

    // MARK: Shortcuts page (registry driven + recording)

    private func buildShortcutsTab() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)

        let hint = NSTextField(wrappingLabelWithString: L10n.t("settings.shortcutHint"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(hint)

        for entry in KeyBindings.registry {
            let label = NSTextField(labelWithString: L10n.t(entry.titleKey))
            label.font = .systemFont(ofSize: 12)
            label.widthAnchor.constraint(equalToConstant: 180).isActive = true
            let recorder = ShortcutRecorderButton(bindingID: entry.id)
            let reset = NSButton()
            reset.image = NSImage(systemSymbolName: "arrow.uturn.backward",
                                  accessibilityDescription: L10n.t("settings.resetKey"))
            reset.isBordered = false
            reset.toolTip = L10n.t("settings.resetKey")
            reset.target = self
            reset.action = #selector(resetBinding(_:))
            reset.identifier = .init(entry.id)
            let row = NSStackView(views: [label, recorder, reset])
            row.orientation = .horizontal
            row.spacing = 8
            stack.addArrangedSubview(row)
        }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
        ])
        return scroll
    }

    @objc private func resetBinding(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        KeyBindings.reset(id)
        KeyBindings.rebuildMenus()
        // Refresh the title of the recorder button in the same row
        if let row = sender.superview as? NSStackView,
           let recorder = row.arrangedSubviews.compactMap({ $0 as? ShortcutRecorderButton }).first {
            recorder.refreshTitle()
        }
    }

    // MARK: Finder Replacement page (original content)

    private let revealCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let revealStatus = NSTextField(wrappingLabelWithString: "")

    private func buildFinderTab() -> NSView {
        // I-28: Reveal takeover (the NSFileViewer global key, same mechanism as QSpace): the "open file location / Show in Finder"
        // family of calls lands in NSpace with the target selected; can be turned off at any time to give it back to Finder
        let revealHeader = NSTextField(labelWithString: L10n.t("settings.reveal.title"))
        revealHeader.font = .systemFont(ofSize: 13, weight: .semibold)
        revealCheck.title = L10n.t("settings.reveal.toggle")
        revealCheck.font = .systemFont(ofSize: 12)
        revealCheck.target = self
        revealCheck.action = #selector(revealToggled(_:))
        revealStatus.font = .systemFont(ofSize: 11)
        refreshRevealState()
        let revealNote = NSTextField(wrappingLabelWithString: L10n.t("settings.reveal.note"))
        revealNote.font = .systemFont(ofSize: 11)
        revealNote.textColor = .tertiaryLabelColor

        // I-25 UI cleanup: with the default handler locked by the OS, the button could only ever fail (a fake button, violating FG-1), so it was replaced with an honest status statement
        let folderHeader = NSTextField(labelWithString: L10n.t("settings.folderDefault.title"))
        folderHeader.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        let limitation = NSTextField(wrappingLabelWithString: L10n.t("settings.limitationNote"))
        limitation.font = .systemFont(ofSize: 11)
        limitation.textColor = .tertiaryLabelColor

        // Full Disk Access buttons and notes all live on the Permissions page (I-09 dedupe); this page keeps only Finder replacement content
        let stack = NSStackView(views: [revealHeader, revealCheck, revealStatus, revealNote,
                                        NSBox.separatorLine(),
                                        folderHeader, statusLabel, limitation])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        return wrap(stack)
    }

    private func wrap(_ stack: NSStackView) -> NSView {
        let v = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: v.topAnchor),
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor),
        ])
        return v
    }

    private func refreshFinderState() {
        if FinderIntegration.isDefaultFolderHandler {
            // Should a future system version unlock this, the status turns green as is
            statusLabel.stringValue = L10n.t("settings.isDefault")
            statusLabel.textColor = .systemGreen
        } else {
            statusLabel.stringValue = L10n.t("settings.folderDefault.locked")
            statusLabel.textColor = .secondaryLabelColor
        }
    }

    /// Refresh Reveal takeover status (three states: NSpace/Finder/other; a stale leftover gets a red warning, and ticking the box repairs it)
    private func refreshRevealState() {
        switch FinderIntegration.revealHandler {
        case .nspace:
            revealCheck.state = .on
            revealStatus.stringValue = L10n.t("settings.reveal.on")
            revealStatus.textColor = .systemGreen
        case .finder:
            revealCheck.state = .off
            revealStatus.stringValue = L10n.t("settings.reveal.off")
            revealStatus.textColor = .secondaryLabelColor
        case .other(let id, let resolvable):
            revealCheck.state = .off
            revealStatus.stringValue = String(format: L10n.t(resolvable ? "settings.reveal.other"
                                                                        : "settings.reveal.stale"), id)
            revealStatus.textColor = resolvable ? .secondaryLabelColor : .systemRed
        }
    }

    @objc private func revealToggled(_ sender: NSButton) {
        FinderIntegration.setRevealTakeover(sender.state == .on)
        refreshRevealState()
        Toast.show(L10n.t(sender.state == .on ? "toast.revealOn" : "toast.revealOff"), in: window)
    }

}

extension NSBox {
    static func separatorLine() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}

/// Shortcut recorder button: click to start recording, pressing a combo saves it; Esc cancels, ⌫ clears
@MainActor
final class ShortcutRecorderButton: NSButton {
    let bindingID: String
    private var monitor: Any?

    init(bindingID: String) {
        self.bindingID = bindingID
        super.init(frame: .zero)
        bezelStyle = .rounded
        font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        target = self
        action = #selector(beginRecording)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        refreshTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    func refreshTitle() {
        title = KeyBindings.display(bindingID)
    }

    @objc private func beginRecording() {
        guard monitor == nil else { return }
        title = L10n.t("settings.pressKey")
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            defer { self.endRecording() }
            if event.keyCode == 53 {  // Esc cancels
                self.refreshTitle()
                return nil
            }
            if event.keyCode == 51 {  // ⌫ clears (no shortcut)
                KeyBindings.set(self.bindingID, key: "", mods: [])
                KeyBindings.rebuildMenus()
                self.refreshTitle()
                return nil
            }
            guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return nil }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            KeyBindings.set(self.bindingID, key: chars.lowercased(), mods: mods)
            KeyBindings.rebuildMenus()
            self.refreshTitle()
            return nil
        }
    }

    private func endRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}


/// Global hotkey recorder button (M24): records keyCode + modifiers (Carbon needs keyCode); at least one modifier; Esc cancels, ⌫ clears
@MainActor
final class GlobalHotkeyRecorderButton: NSButton {
    private var monitor: Any?

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        target = self
        action = #selector(beginRecording)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        refreshTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    func refreshTitle() {
        title = GlobalHotkey.current?.display ?? L10n.t("settings.globalHotkey.unset")
    }

    @objc private func beginRecording() {
        guard monitor == nil else { return }
        title = L10n.t("settings.pressKey")
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            defer { self.endRecording() }
            if event.keyCode == 53 { self.refreshTitle(); return nil }          // Esc cancels
            if event.keyCode == 51 {                                             // ⌫ clears
                GlobalHotkey.clear()
                self.refreshTitle()
                return nil
            }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !mods.isEmpty else { NSSound.beep(); self.refreshTitle(); return nil }
            var disp = ""
            if mods.contains(.control) { disp += "⌃" }
            if mods.contains(.option) { disp += "⌥" }
            if mods.contains(.shift) { disp += "⇧" }
            if mods.contains(.command) { disp += "⌘" }
            let keyName: String = {
                switch event.keyCode {
                case 49: return "Space"
                case 36: return "↩"
                case 48: return "⇥"
                default: return (event.charactersIgnoringModifiers ?? "?").uppercased()
                }
            }()
            GlobalHotkey.set(mods: mods, keyCode: UInt32(event.keyCode), display: disp + keyName)
            self.refreshTitle()
            Toast.show(L10n.t("toast.globalHotkeySet"), in: self.window)
            return nil
        }
    }

    private func endRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}


// MARK: - Settings search results table (data source/delegate)

extension SettingsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { hits.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard hits.indices.contains(row) else { return nil }
        let id = NSUserInterfaceItemIdentifier("settingsHit")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView)
            ?? {
                let c = NSTableCellView()
                c.identifier = id
                let tf = NSTextField(labelWithString: "")
                tf.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
                tf.lineBreakMode = .byTruncatingTail
                tf.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(tf)
                c.textField = tf
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                    tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                    tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                return c
            }()
        let h = hits[row]
        // Include "which page": with only the item name, users would have to find the page themselves after jumping
        cell.textField?.stringValue = "\(h.text)  ·  \(h.tabLabel)"
        return cell
    }
}
