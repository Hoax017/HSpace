import AppKit
import ContextMenuLayout

/// The two context menus the owner can arrange (L64)
enum ContextMenuKind: String, CaseIterable {
    /// Right-click on a selection
    case item
    /// Right-click on empty space
    case directory

    var titleKey: String { "settings.contextMenu.kind.\(rawValue)" }
}

/// Every top-level entry the context menus can show, in their default sections (the menu's separators).
/// An entry shows only when it applies, for example Extract for an archive, but it is listed here always.
@MainActor
enum ContextMenuCatalog {
    struct Entry {
        let id: String
        let titleKey: String
    }

    static func sections(_ kind: ContextMenuKind) -> [[Entry]] {
        switch kind {
        case .item: itemSections
        case .directory: directorySections
        }
    }

    static func ids(_ kind: ContextMenuKind) -> [[String]] { sections(kind).map { $0.map(\.id) } }

    static func entry(_ id: String, in kind: ContextMenuKind) -> Entry? {
        sections(kind).joined().first { $0.id == id }
    }

    private static func e(_ id: String, _ titleKey: String? = nil) -> Entry {
        Entry(id: id, titleKey: titleKey ?? "menu.\(id)")
    }

    private static let itemSections: [[Entry]] = [
        [e("open"), e("openWith")],
        [e("copy"), e("cut"), e("paste"), e("copyPath")],
        [e("addBookmark")],
        [e("tags"), e("editComment"), e("fileColor"), e("editFolderIcon"), e("removeFolderIcon"), e("hideItems")],
        [e("rename"), e("duplicate"), e("putBack"), e("moveToTrash")],
        [e("batchTools")],
        [e("compress", "settings.contextMenu.compress"), e("compressWithPassword"), e("extract"), e("extractTo"),
         e("browseArchive")],
        [e("newFolder"), e("newFile"), e("newFromTemplate"), e("getInfo"), e("openInTerminal"), e("showPackageContents")],
    ]

    private static let directorySections: [[Entry]] = [
        [e("newFolder"), e("newFile"), e("newFromTemplate"), e("paste")],
        [e("filterByTag"), e("sortByTags")],
        [e("batchTools"), e("getInfo"), e("openInTerminal")],
    ]
}

/// Applies the owner's layout to a context menu that was just built
@MainActor
enum ContextMenuCustomization {
    static func defaultsKeys(_ kind: ContextMenuKind) -> (hidden: String, order: String) {
        ("contextMenu.\(kind.rawValue).hidden", "contextMenu.\(kind.rawValue).order")
    }

    /// A self-test run sees the default menus, whatever the owner chose
    static func settings(_ kind: ContextMenuKind, defaults: UserDefaults = .standard) -> ContextMenuSettings {
        guard !TestIsolation.isActive else { return ContextMenuSettings() }
        let keys = defaultsKeys(kind)
        return ContextMenuSettings(hidden: defaults.stringArray(forKey: keys.hidden) ?? [],
                                   order: defaults.stringArray(forKey: keys.order) ?? [])
    }

    static func save(_ settings: ContextMenuSettings, _ kind: ContextMenuKind, defaults: UserDefaults = .standard) {
        let keys = defaultsKeys(kind)
        if settings.hidden.isEmpty { defaults.removeObject(forKey: keys.hidden) } else { defaults.set(settings.hidden, forKey: keys.hidden) }
        if settings.order.isEmpty { defaults.removeObject(forKey: keys.order) } else { defaults.set(settings.order, forKey: keys.order) }
    }

    static func apply(to menu: NSMenu, kind: ContextMenuKind) {
        apply(to: menu, settings: settings(kind))
    }

    /// Rebuilds the menu's top level in the arranged order. The menu's own sections are kept: an entry never crosses a
    /// separator. An item without an id stays where it is, at the end of its section.
    static func apply(to menu: NSMenu, settings: ContextMenuSettings) {
        guard !settings.isDefault else { return }
        var sections: [[NSMenuItem]] = [[]]
        for item in menu.items {
            if item.isSeparatorItem { sections.append([]) } else { sections[sections.count - 1].append(item) }
        }
        sections = sections.filter { !$0.isEmpty }
        let arranged = settings.arranged(sections.map { $0.compactMap(\.identifier?.rawValue) })
        var byID: [String: NSMenuItem] = [:]
        for item in sections.joined() { if let id = item.identifier?.rawValue { byID[id] = item } }

        // Pair each arranged section back with the items it came from, plus that section's items without an id
        var rebuilt: [[NSMenuItem]] = []
        var next = arranged.makeIterator()
        var pending = next.next()
        for section in sections {
            let ids = Set(section.compactMap(\.identifier?.rawValue))
            var items: [NSMenuItem] = []
            if let ordered = pending, !ordered.isEmpty, ids.contains(ordered[0]) {
                items = ordered.compactMap { byID[$0] }
                pending = next.next()
            }
            items += section.filter { $0.identifier == nil }
            if !items.isEmpty { rebuilt.append(items) }
        }
        menu.removeAllItems()
        for (i, section) in rebuilt.enumerated() {
            if i > 0 { menu.addItem(.separator()) }
            section.forEach(menu.addItem)
        }
    }
}

/// Chooses which context menu entries show and in what order. Changes apply to the next menu opened.
@MainActor
final class ContextMenuSettingsPage: NSObject, SettingsPage {
    var pageTitleKey: String { "settings.tab.contextMenu" }

    private(set) var kind: ContextMenuKind = .item
    private(set) var settings = ContextMenuSettings()
    private let rows = NSStackView()
    private let kindPopup = NSPopUpButton()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func makeView() -> NSView {
        settings = ContextMenuCustomization.settings(kind, defaults: defaults)
        let note = NSTextField(wrappingLabelWithString: L10n.t("settings.contextMenu.note"))
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        kindPopup.removeAllItems()
        kindPopup.addItems(withTitles: ContextMenuKind.allCases.map { L10n.t($0.titleKey) })
        kindPopup.target = self
        kindPopup.action = #selector(kindChanged(_:))
        kindPopup.setAccessibilityLabel(L10n.t("settings.contextMenu.kind"))
        let kindRow = NSStackView(views: [ToolUI.label(L10n.t("settings.contextMenu.kind"), size: 13, color: .labelColor), kindPopup])
        kindRow.spacing = 8
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 4
        rebuildRows()
        let reset = NSButton(title: L10n.t("settings.contextMenu.reset"), target: self, action: #selector(resetLayout(_:)))

        let stack = NSStackView(views: [note, kindRow, rows, reset])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = stack
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
        ])
        return scroll
    }

    /// Titles of the rows on show, for tests: section breaks are "—"
    var rowTitles: [String] {
        rows.arrangedSubviews.map { view in
            (view as? NSStackView)?.arrangedSubviews.compactMap { ($0 as? NSButton)?.title }.first { !$0.isEmpty } ?? "—"
        }
    }

    private func rebuildRows() {
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let ordered = settings.ordered(ContextMenuCatalog.ids(kind))
        for (s, section) in ordered.enumerated() {
            if s > 0 {
                let line = NSBox()
                line.boxType = .separator
                line.widthAnchor.constraint(equalToConstant: 296).isActive = true
                rows.addArrangedSubview(line)
            }
            for (index, id) in section.enumerated() {
                guard let entry = ContextMenuCatalog.entry(id, in: kind) else { continue }
                rows.addArrangedSubview(row(entry, first: index == 0, last: index == section.count - 1))
            }
        }
    }

    private func row(_ entry: ContextMenuCatalog.Entry, first: Bool, last: Bool) -> NSView {
        let title = L10n.t(entry.titleKey)
        let check = ToolUI.check(title, target: self, action: #selector(toggled(_:)))
        check.state = settings.isHidden(entry.id) ? .off : .on
        check.identifier = NSUserInterfaceItemIdentifier(entry.id)
        check.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let up = moveButton("chevron.up", L10n.f("settings.contextMenu.up", title), entry.id, #selector(moveUp(_:)))
        up.isEnabled = !first
        let down = moveButton("chevron.down", L10n.f("settings.contextMenu.down", title), entry.id, #selector(moveDown(_:)))
        down.isEnabled = !last
        let row = NSStackView(views: [check, up, down])
        row.orientation = .horizontal
        row.spacing = 4
        return row
    }

    private func moveButton(_ symbol: String, _ label: String, _ id: String, _ selector: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(),
                              target: self, action: selector)
        button.isBordered = false
        button.setAccessibilityLabel(label)
        button.toolTip = label
        button.identifier = NSUserInterfaceItemIdentifier(id)
        return button
    }

    private func commit() {
        ContextMenuCustomization.save(settings, kind, defaults: defaults)
        rebuildRows()
    }

    func select(_ kind: ContextMenuKind) {
        self.kind = kind
        kindPopup.selectItem(at: ContextMenuKind.allCases.firstIndex(of: kind) ?? 0)
        settings = ContextMenuCustomization.settings(kind, defaults: defaults)
        rebuildRows()
    }

    func setShown(_ id: String, _ shown: Bool) {
        settings.setHidden(id, !shown)
        commit()
    }

    func move(_ id: String, by offset: Int) {
        settings.move(id, by: offset, in: ContextMenuCatalog.ids(kind))
        commit()
    }

    @objc private func kindChanged(_ sender: NSPopUpButton) {
        select(ContextMenuKind.allCases[max(0, sender.indexOfSelectedItem)])
    }

    @objc private func toggled(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        setShown(id, sender.state == .on)
    }

    @objc private func moveUp(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        move(id, by: -1)
    }

    @objc private func moveDown(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        move(id, by: 1)
    }

    @objc func resetLayout(_ sender: Any?) {
        settings = ContextMenuSettings()
        commit()
    }
}
