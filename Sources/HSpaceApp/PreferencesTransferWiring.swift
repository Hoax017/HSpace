import AppKit
import FolderSize
import PreferencesTransfer
import ViewStyles

/// The settings that travel in a preferences file (L65), and what each may hold. Window places, session state, the
/// Full Disk Access prompt flag and recent tags stay with this Mac. Archive passwords live in the Keychain and never travel:
/// the schema refuses any key that looks like a secret.
@MainActor
enum PreferencesCatalog {
    static func schema() -> PreferenceSchema {
        do {
            return try PreferenceSchema(kinds)
        } catch {
            preconditionFailure("The preferences schema names a secret: \(error.localizedDescription)")
        }
    }

    private static func choices(_ words: [String]) -> PreferenceKind { .choice(Set(words)) }

    static var kinds: [String: PreferenceKind] {
        var kinds: [String: PreferenceKind] = [
            "defaultLayout": .integer(PaneLayout.allCases.map(\.rawValue).min()!...PaneLayout.allCases.map(\.rawValue).max()!),
            "defaultViewMode": .integer(0...2),
            "showHiddenByDefault": .bool,
            "foldersFirst": .bool,
            "bringToActiveSpace": .bool,
            "dragShake": .bool,
            "terminalChoice": .text(pattern: "auto|[A-Za-z0-9.-]{1,255}"),
            "visibleColumns": .list(maxCount: 32, pattern: "[A-Za-z]{1,32}"),
            "listGrouping": .bool,
            "searchSmartSort": .bool,
            "sidebarGroupOrder": .list(maxCount: 3, pattern: "bookmarks|icloud|volumes"),
            "archiveFormat": choices(Preferences.archiveFormatOptions.map(\.id)),
            "archiveKeepOriginal": .bool,
            "extractCreateWrapper": .bool,
            "extractKeepArchive": .bool,
            "maxConcurrentOperations": .integer(1...4),
            "archiveCompression": choices(Preferences.archiveCompressionOptions.map(\.id)),
            "enterAction": choices(["rename", "open"]),
            "backspaceAction": choices(["ignore", "back", "delete", "up"]),
            "dragBehavior": choices(["auto", "copy", "move"]),
            "doubleClickBlank": .bool,
            "defaultSortKey": choices(["name", "dateModified", "size", "kind", "created", "added"]),
            "defaultSortAscending": .bool,
            "workspaceTabLimit": .integer(0...99),
            "externalOpenTarget": choices(["newTab", "newWindow", "activePane"]),
            "appearanceMode": choices(["system", "light", "dark"]),
            "accentColorHex": .text(pattern: "[0-9A-Fa-f]{6}"),
            "listFontSize": .integer(11...14),
            "activePaneHighlight": .bool,
            "inactivePaneDimming": .number(0...0.3),
            "folderSizeMode": choices(FolderSizeMode.allCases.map(\.rawValue)),
            "iconGridSize": .number(Double(IconLayout.sizes.lowerBound)...Double(IconLayout.sizes.upperBound)),
            "iconGridSpacing": .integer(IconLayout.spacings.min()!...IconLayout.spacings.max()!),
            "iconLabelPosition": choices(IconLabelPosition.allCases.map(\.rawValue)),
            "spaceSelects": .bool,
            "previewPanelVisible": .bool,
            "inspectorPanelVisible": .bool,
            "detailPanelWidth": .number(0...10_000),
            "panelActions": .list(maxCount: PanelAction.all.count, pattern: PanelAction.all.map { NSRegularExpression.escapedPattern(for: $0.id) }.joined(separator: "|")),
            // "modifiers|key code|label"
            GlobalHotkey.prefKey: .text(pattern: "[0-9]{1,20}\\|[0-9]{1,10}\\|.{1,32}"),
        ]
        // "modifiers|key"
        for entry in KeyBindings.registry { kinds["kb.\(entry.id)"] = .text(pattern: "[0-9]{1,20}\\|.{0,4}") }
        for kind in ContextMenuKind.allCases {
            let keys = ContextMenuCustomization.defaultsKeys(kind)
            kinds[keys.hidden] = .list(maxCount: 256, pattern: "[A-Za-z]{1,64}")
            kinds[keys.order] = .list(maxCount: 256, pattern: "[A-Za-z]{1,64}")
        }
        return kinds
    }
}

/// Moves settings between UserDefaults and a preferences file
@MainActor
struct PreferencesTransfer {
    let defaults: UserDefaults
    let schema: PreferenceSchema

    init(defaults: UserDefaults = .standard, schema: PreferenceSchema = PreferencesCatalog.schema()) {
        self.defaults = defaults
        self.schema = schema
    }

    /// The settings the owner changed from their defaults. A stored value of the wrong type is read as not set.
    func snapshot() -> [String: PreferenceValue] {
        var values: [String: PreferenceValue] = [:]
        for (key, kind) in schema.kinds {
            guard let raw = defaults.object(forKey: key) else { continue }
            let value: PreferenceValue? = switch kind {
            case .bool: (raw as? Bool).map(PreferenceValue.bool)
            case .integer: (raw as? Int).map(PreferenceValue.integer)
            case .number: (raw as? Double).map(PreferenceValue.number)
            case .choice, .text: (raw as? String).map(PreferenceValue.text)
            case .list: (raw as? [String]).map(PreferenceValue.list)
            }
            if let value { values[key] = value }
        }
        return values
    }

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// Returns the keys left out because their stored value does not fit
    @discardableResult
    func export(to url: URL) throws -> [String] {
        let (data, left) = try PreferencesFile.encode(snapshot(), schema: schema, appVersion: appVersion)
        try PreferencesFile.write(data, to: url)
        return left
    }

    /// Makes the settings equal to the document: what it lists is set, every other travelling setting goes back to its default
    func apply(_ document: PreferencesDocument) {
        for key in schema.kinds.keys {
            switch document.values[key] {
            case .bool(let value): defaults.set(value, forKey: key)
            case .integer(let value): defaults.set(value, forKey: key)
            case .number(let value): defaults.set(value, forKey: key)
            case .text(let value): defaults.set(value, forKey: key)
            case .list(let value): defaults.set(value, forKey: key)
            case nil: defaults.removeObject(forKey: key)
            }
        }
    }

    /// Keeps the current settings beside the app data before an import replaces them
    func backUp(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("preferences-before-import.json")
        let (data, _) = try PreferencesFile.encode(snapshot(), schema: schema, appVersion: appVersion)
        try PreferencesFile.write(data, to: url)
        return url
    }
}

extension AppDelegate {
    @objc func exportPreferences(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.title = L10n.t("prefs.export.title")
        panel.nameFieldStringValue = L10n.t("prefs.export.fileName")
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let left = try PreferencesTransfer().export(to: url)
            let note = left.isEmpty ? L10n.t("prefs.export.done") : L10n.f("prefs.export.doneSkipped", left.count)
            Toast.show(note, in: frontmostMainWindow)
        } catch {
            showPreferencesProblem(L10n.t("prefs.export.failed"), error)
        }
    }

    @objc func importPreferences(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = L10n.t("prefs.import.title")
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let transfer = PreferencesTransfer()
        let document: PreferencesDocument
        do {
            document = try PreferencesFile.read(from: url, schema: transfer.schema)
        } catch {
            showPreferencesProblem(L10n.t("prefs.import.failed"), error)
            return
        }

        let confirm = NSAlert()
        confirm.messageText = L10n.f("prefs.import.confirm", url.lastPathComponent)
        confirm.informativeText = L10n.f("prefs.import.confirmDetail", document.values.count)
        confirm.addButton(withTitle: L10n.t("prefs.import.replace"))
        confirm.addButton(withTitle: L10n.t("common.cancel"))
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        // Nothing changes unless the current settings are safely kept first
        let backup: URL
        do {
            backup = try transfer.backUp(in: AppDelegate.supportDirectory)
        } catch {
            showPreferencesProblem(L10n.t("prefs.import.failed"), error)
            return
        }
        transfer.apply(document)
        applyImportedPreferences()

        let done = NSAlert()
        done.messageText = L10n.t("prefs.import.done")
        done.informativeText = L10n.f("prefs.import.doneDetail", backup.path)
        done.runModal()
    }

    /// What can take the new values at once does so. New panes and windows read the rest when they open.
    func applyImportedPreferences() {
        Theme.broadcastChanged()
        KeyBindings.rebuildMenus()
        GlobalHotkey.apply()
        dragShake.setEnabled(Preferences.dragShake)
        NotificationCenter.default.post(name: .hspacePanelActionsChanged, object: nil)
    }

    private func showPreferencesProblem(_ title: String, _ error: any Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
