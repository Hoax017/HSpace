import AppKit
import WindowRules

/// The stored window options and app exclusions (L66)
@MainActor
enum WindowSettings {
    static let launchKey = "windowLaunch"
    static let newWindowKey = "newWindowFolder"
    static let lastTabKey = "lastTabClose"
    static let quitKey = "quitAfterLastWindow"
    static let exclusionsKey = "excludedApps"

    static func options(_ defaults: UserDefaults = .standard) -> WindowOptions {
        WindowOptions(launch: defaults.string(forKey: launchKey), newWindow: defaults.string(forKey: newWindowKey),
                      lastTab: defaults.string(forKey: lastTabKey), quitAfterLastWindow: defaults.object(forKey: quitKey) as? Bool)
    }

    static func save(_ options: WindowOptions, _ defaults: UserDefaults = .standard) {
        defaults.set(options.launch.rawValue, forKey: launchKey)
        defaults.set(options.newWindow.rawValue, forKey: newWindowKey)
        defaults.set(options.lastTab.rawValue, forKey: lastTabKey)
        defaults.set(options.quitAfterLastWindow, forKey: quitKey)
    }

    static func exclusions(_ defaults: UserDefaults = .standard) -> AppExclusions {
        AppExclusions(defaults.stringArray(forKey: exclusionsKey) ?? [])
    }

    static func save(_ exclusions: AppExclusions, _ defaults: UserDefaults = .standard) {
        if exclusions.isEmpty { defaults.removeObject(forKey: exclusionsKey) } else { defaults.set(exclusions.bundleIDs, forKey: exclusionsKey) }
    }
}

/// Follows which app is in front, and says when the global triggers must stand down. It listens only while the list
/// has apps, and only to app switches: nothing runs at rest.
@MainActor
final class AppExclusionMonitor {
    /// Called with the new state whenever it changes
    var onChange: ((Bool) -> Void)?
    private(set) var isSilenced = false
    private(set) var exclusions = AppExclusions()
    private let center: NotificationCenter
    private let own: String?
    private let frontmost: () -> String?
    private var observer: (any NSObjectProtocol)?

    init(center: NotificationCenter = NSWorkspace.shared.notificationCenter,
         own: String? = Bundle.main.bundleIdentifier,
         frontmost: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }) {
        self.center = center
        self.own = own
        self.frontmost = frontmost
    }

    var isListening: Bool { observer != nil }

    func update(_ exclusions: AppExclusions) {
        self.exclusions = exclusions
        if exclusions.isEmpty, let observer {
            center.removeObserver(observer)
            self.observer = nil
        } else if !exclusions.isEmpty, observer == nil {
            observer = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let id = app?.bundleIdentifier
                MainActor.assumeIsolated { self?.frontmostChanged(id) }
            }
        }
        frontmostChanged(frontmost())
    }

    func frontmostChanged(_ bundleID: String?) {
        let silenced = exclusions.silences(frontmost: bundleID, own: own)
        guard silenced != isSilenced else { return }
        isSilenced = silenced
        onChange?(silenced)
    }

    func stop() {
        if let observer { center.removeObserver(observer) }
        observer = nil
    }
}

extension AppDelegate {
    /// Hooks the exclusions to the hotkey; the drag-shake asks `isSilenced` when it fires
    func startAppExclusions() {
        exclusionMonitor.onChange = { GlobalHotkey.setSuspended($0) }
        exclusionMonitor.update(WindowSettings.exclusions())
    }

    /// The folder File > New Window opens at
    func newWindowFolder() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let current = mainWindowController(for: frontmostMainWindow)?.grid.activePane.activeTab.model.directory
        return WindowSettings.options().newWindowFolder(home: home, current: current) { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }
}

/// Window and workspace options, and the apps HSpace's global triggers leave alone
@MainActor
final class WindowsSettingsPage: NSObject, SettingsPage {
    var pageTitleKey: String { "settings.tab.windows" }

    private let defaults: UserDefaults
    private let launchPopup = NSPopUpButton()
    private let newWindowPopup = NSPopUpButton()
    private let lastTabPopup = NSPopUpButton()
    private let quitCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let appRows = NSStackView()
    /// Where the page reports what it changed; the app passes its exclusion monitor
    var onExclusionsChanged: ((AppExclusions) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func makeView() -> NSView {
        let options = WindowSettings.options(defaults)
        fill(launchPopup, LaunchWindows.allCases.map { "settings.windows.launch.\($0.rawValue)" },
             selected: LaunchWindows.allCases.firstIndex(of: options.launch) ?? 0, label: "settings.windows.launch")
        fill(newWindowPopup, NewWindowFolder.allCases.map { "settings.windows.newWindow.\($0.rawValue)" },
             selected: NewWindowFolder.allCases.firstIndex(of: options.newWindow) ?? 0, label: "settings.windows.newWindow")
        fill(lastTabPopup, LastTabClose.allCases.map { "settings.windows.lastTab.\($0.rawValue)" },
             selected: LastTabClose.allCases.firstIndex(of: options.lastTab) ?? 0, label: "settings.windows.lastTab")
        quitCheck.title = L10n.t("settings.windows.quit")
        quitCheck.state = options.quitAfterLastWindow ? .on : .off
        quitCheck.target = self
        quitCheck.action = #selector(optionChanged(_:))

        let grid = NSGridView(views: [
            [ToolUI.label(L10n.t("settings.windows.launch"), size: 13, color: .labelColor), launchPopup],
            [ToolUI.label(L10n.t("settings.windows.newWindow"), size: 13, color: .labelColor), newWindowPopup],
            [ToolUI.label(L10n.t("settings.windows.lastTab"), size: 13, color: .labelColor), lastTabPopup],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing

        let appsTitle = ToolUI.label(L10n.t("settings.windows.excluded"), size: 13, color: .labelColor)
        let appsNote = NSTextField(wrappingLabelWithString: L10n.t("settings.windows.excludedNote"))
        appsNote.font = .systemFont(ofSize: 11)
        appsNote.textColor = .secondaryLabelColor
        appRows.orientation = .vertical
        appRows.alignment = .leading
        appRows.spacing = 4
        rebuildApps()
        let add = NSButton(title: L10n.t("settings.windows.addApp"), target: self, action: #selector(addApp(_:)))

        let stack = NSStackView(views: [grid, quitCheck, appsTitle, appsNote, appRows, add])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(20, after: quitCheck)
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        appsNote.widthAnchor.constraint(lessThanOrEqualToConstant: 440).isActive = true
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        ])
        return container
    }

    private func fill(_ popup: NSPopUpButton, _ keys: [String], selected: Int, label: String) {
        popup.removeAllItems()
        popup.addItems(withTitles: keys.map { L10n.t($0) })
        popup.selectItem(at: selected)
        popup.target = self
        popup.action = #selector(optionChanged(_:))
        popup.setAccessibilityLabel(L10n.t(label))
    }

    /// The options the controls show
    var shownOptions: WindowOptions {
        WindowOptions(launch: LaunchWindows.allCases[max(0, launchPopup.indexOfSelectedItem)],
                      newWindow: NewWindowFolder.allCases[max(0, newWindowPopup.indexOfSelectedItem)],
                      lastTab: LastTabClose.allCases[max(0, lastTabPopup.indexOfSelectedItem)],
                      quitAfterLastWindow: quitCheck.state == .on)
    }

    func select(launch: LaunchWindows? = nil, newWindow: NewWindowFolder? = nil, lastTab: LastTabClose? = nil, quit: Bool? = nil) {
        if let launch { launchPopup.selectItem(at: LaunchWindows.allCases.firstIndex(of: launch) ?? 0) }
        if let newWindow { newWindowPopup.selectItem(at: NewWindowFolder.allCases.firstIndex(of: newWindow) ?? 0) }
        if let lastTab { lastTabPopup.selectItem(at: LastTabClose.allCases.firstIndex(of: lastTab) ?? 0) }
        if let quit { quitCheck.state = quit ? .on : .off }
        optionChanged(nil)
    }

    @objc private func optionChanged(_ sender: Any?) {
        WindowSettings.save(shownOptions, defaults)
    }

    // MARK: Excluded apps

    var shownAppIDs: [String] { appRows.arrangedSubviews.compactMap { $0.identifier?.rawValue } }

    private func rebuildApps() {
        appRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let ids = WindowSettings.exclusions(defaults).bundleIDs
        if ids.isEmpty {
            appRows.addArrangedSubview(ToolUI.label(L10n.t("settings.windows.excludedNone"), size: 11, color: .tertiaryLabelColor))
        }
        for id in ids { appRows.addArrangedSubview(appRow(id)) }
    }

    private func appRow(_ id: String) -> NSView {
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        let name = appURL.map { FileManager.default.displayName(atPath: $0.path) } ?? id
        let icon = NSImageView(image: appURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage())
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let title = ToolUI.label(name, size: 13, color: appURL == nil ? .tertiaryLabelColor : .labelColor)
        title.toolTip = id
        title.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let removeLabel = L10n.f("settings.windows.removeApp", name)
        let remove = NSButton(image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: removeLabel) ?? NSImage(),
                              target: self, action: #selector(removeApp(_:)))
        remove.isBordered = false
        remove.toolTip = removeLabel
        remove.setAccessibilityLabel(removeLabel)
        remove.identifier = NSUserInterfaceItemIdentifier(id)
        let row = NSStackView(views: [icon, title, remove])
        row.orientation = .horizontal
        row.spacing = 8
        row.identifier = NSUserInterfaceItemIdentifier(id)
        return row
    }

    /// False, with nothing changed, when the app has no usable bundle id
    @discardableResult
    func exclude(appAt url: URL) -> Bool {
        guard let id = Bundle(url: url)?.bundleIdentifier, AppExclusions.isBundleID(id) else { return false }
        var list = WindowSettings.exclusions(defaults)
        list.add(id)
        commit(list)
        return true
    }

    func include(_ bundleID: String) {
        var list = WindowSettings.exclusions(defaults)
        list.remove(bundleID)
        commit(list)
    }

    private func commit(_ list: AppExclusions) {
        WindowSettings.save(list, defaults)
        if let onExclusionsChanged { onExclusionsChanged(list) } else { (NSApp.delegate as? AppDelegate)?.exclusionMonitor.update(list) }
        rebuildApps()
    }

    @objc private func addApp(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = L10n.t("settings.windows.addApp")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        let refused = panel.urls.filter { !exclude(appAt: $0) }
        guard !refused.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = L10n.t("settings.windows.addAppFailed")
        alert.informativeText = refused.map(\.lastPathComponent).joined(separator: ", ")
        alert.runModal()
    }

    @objc private func removeApp(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        include(id)
    }
}
