import AppKit
import HSpaceContracts
import FileMetadata

/// What the metadata menus need from a content view (list, icon or column). Lets the three views share one implementation.
@MainActor
protocol MetadataMenuHost: AnyObject {
    var coordinator: FileOpsCoordinator? { get }
    var metadataModel: DirectoryViewModel { get }
    /// Metadata already loaded for these items. Menus must not touch the disk: a slow volume would freeze the click.
    func metadata(for urls: [URL]) -> [URL: ItemMetadata]
}

/// Builds the metadata entries of the context menus (the builder itself stays one line per entry).
@MainActor
enum MetadataMenu {
    static func addItemEntries(to menu: NSMenu, selection: [FileItem], target: AnyObject) {
        guard let host = target as? MetadataMenuHost, let actions = host.coordinator?.metadataActions else { return }
        let urls = selection.map(\.url)
        let loaded = host.metadata(for: urls)
        let lists = urls.map { loaded[$0]?.tags ?? [] }

        let parent = NSMenuItem(title: L10n.t("menu.tags"), action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "tag", accessibilityDescription: nil)
        let submenu = NSMenu()
        for tag in offeredTags(host: host, extra: lists) {
            let holders = lists.filter { TagQuery.matches($0, anyOf: [tag.name]) }.count
            let item = NSMenuItem(title: tag.name, action: #selector(MetadataActions.toggleTag(_:)), keyEquivalent: "")
            item.target = actions
            item.image = TagPalette.menuImage(tag.color)
            item.state = holders == 0 ? .off : (holders == lists.count ? .on : .mixed)
            item.representedObject = MetadataActions.TagToggle(urls: urls, tag: tag, remove: holders == lists.count)
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let edit = NSMenuItem(title: L10n.t("menu.editTags"), action: #selector(MetadataActions.editTagsFromMenu(_:)),
                              keyEquivalent: "")
        edit.target = actions
        edit.representedObject = MetadataActions.EditTarget(items: selection, host: host)
        submenu.addItem(edit)
        parent.submenu = submenu
        menu.addItem(FileContextMenuBuilder.tagged(parent, "tags"))

        let comment = NSMenuItem(title: L10n.t("menu.editComment"),
                                 action: #selector(MetadataActions.editCommentFromMenu(_:)), keyEquivalent: "")
        comment.target = actions
        comment.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil)
        comment.representedObject = MetadataActions.EditTarget(items: selection, host: host)
        menu.addItem(FileContextMenuBuilder.tagged(comment, "editComment"))

        menu.addItem(FileContextMenuBuilder.tagged(colorMenu(urls: urls, loaded: loaded, actions: actions), "fileColor"))

        let folders = selection.filter(MetadataActions.isFolder)
        guard !folders.isEmpty else { return }
        let icon = NSMenuItem(title: L10n.t("menu.editFolderIcon"),
                              action: #selector(MetadataActions.editFolderIconFromMenu(_:)), keyEquivalent: "")
        icon.target = actions
        icon.image = NSImage(systemSymbolName: "folder.badge.gearshape", accessibilityDescription: nil)
        icon.representedObject = MetadataActions.EditTarget(items: folders, host: host)
        menu.addItem(FileContextMenuBuilder.tagged(icon, "editFolderIcon"))
        let custom = folders.filter { loaded[$0.url]?.hasCustomIcon == true }.map(\.url)
        guard !custom.isEmpty else { return }
        let remove = NSMenuItem(title: L10n.t("menu.removeFolderIcon"),
                                action: #selector(MetadataActions.removeFolderIcon(_:)), keyEquivalent: "")
        remove.target = actions
        remove.representedObject = custom
        menu.addItem(FileContextMenuBuilder.tagged(remove, "removeFolderIcon"))
    }

    private static func colorMenu(urls: [URL], loaded: [URL: ItemMetadata], actions: MetadataActions) -> NSMenuItem {
        let parent = NSMenuItem(title: L10n.t("menu.fileColor"), action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: nil)
        let submenu = NSMenu()
        let colors = Set(urls.map { loaded[$0]?.color })
        for color in [nil] + FileColor.allCases.map(Optional.some) {
            let title = color.map(FileColorPalette.name) ?? L10n.t("fileColor.none")
            let item = NSMenuItem(title: title, action: #selector(MetadataActions.setFileColor(_:)), keyEquivalent: "")
            item.target = actions
            item.image = color.flatMap(FileColorPalette.menuImage)
            item.state = colors.contains(color) ? (colors.count == 1 ? .on : .mixed) : .off
            item.representedObject = MetadataActions.ColorChoice(urls: urls, color: color)
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    static func addDirectoryEntries(to menu: NSMenu, target: AnyObject) {
        guard let host = target as? MetadataMenuHost, let actions = host.coordinator?.metadataActions else { return }
        let model = host.metadataModel

        let parent = NSMenuItem(title: L10n.t("menu.filterByTag"), action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: nil)
        let submenu = NSMenu()
        for tag in TagQuery.known(in: model.metadata.values.map(\.tags)) {
            let item = NSMenuItem(title: tag.name, action: #selector(MetadataActions.toggleFilter(_:)), keyEquivalent: "")
            item.target = actions
            item.image = TagPalette.menuImage(tag.color)
            item.state = TagQuery.matches([tag], anyOf: model.tagFilter) ? .on : .off
            item.representedObject = MetadataActions.FilterChoice(model: model, name: tag.name)
            submenu.addItem(item)
        }
        if submenu.items.isEmpty {
            let none = NSMenuItem(title: L10n.t("menu.filterByTag.none"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
        }
        parent.submenu = submenu
        menu.addItem(FileContextMenuBuilder.tagged(parent, "filterByTag"))

        let sort = NSMenuItem(title: L10n.t("menu.sortByTags"), action: #selector(MetadataActions.toggleTagSort(_:)),
                              keyEquivalent: "")
        sort.target = actions
        sort.state = model.tagSortAscending == nil ? .off : .on
        sort.representedObject = model
        menu.addItem(FileContextMenuBuilder.tagged(sort, "sortByTags"))
    }

    /// The kind a file can set a default app for, or nil
    static func defaultAppKind(of file: FileItem) -> String? {
        guard !file.isDirectory, DefaultApps.canChange(typeID: file.contentTypeID) else { return nil }
        return file.contentTypeID
    }

    /// "Always Open With" under Open With, with the same apps plus a chooser
    static func addDefaultAppEntries(to menu: NSMenu, file: FileItem, apps: [URL], target: AnyObject) {
        guard let typeID = defaultAppKind(of: file),
              let actions = (target as? MetadataMenuHost)?.coordinator?.metadataActions else { return }
        let kindName = Formatters.kind(forTypeID: typeID, isDirectory: false)
        let parent = NSMenuItem(title: L10n.t("menu.alwaysOpenWith"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for app in apps {
            let item = NSMenuItem(title: FileManager.default.displayName(atPath: app.path),
                                  action: #selector(MetadataActions.chooseDefaultApp(_:)), keyEquivalent: "")
            item.target = actions
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            item.representedObject = MetadataActions.DefaultAppChoice(typeID: typeID, kindName: kindName, app: app)
            submenu.addItem(item)
        }
        if !apps.isEmpty { submenu.addItem(.separator()) }
        let other = NSMenuItem(title: L10n.t("openWith.other"),
                               action: #selector(MetadataActions.chooseOtherDefaultApp(_:)), keyEquivalent: "")
        other.target = actions
        other.representedObject = MetadataActions.DefaultAppChoice(typeID: typeID, kindName: kindName, app: nil)
        submenu.addItem(other)
        parent.submenu = submenu
        menu.addItem(.separator())
        menu.addItem(parent)
    }

    /// Finder's seven, then recent tags and those in view
    static func offeredTags(host: MetadataMenuHost, extra: [[FinderTag]]) -> [FinderTag] {
        let inView = host.metadataModel.metadata.values.map(\.tags)
        let others = TagQuery.known(in: inView + extra + [Preferences.recentTags])
            .filter { tag in !FinderTag.standard.contains { TagQuery.sameName($0.name, tag.name) } }
        return FinderTag.standard + others
    }
}

/// Menu item target. A plain object, because menu items keep their target weakly and need something with @objc methods.
@MainActor
final class MetadataActions: NSObject {
    struct TagToggle {
        let urls: [URL]
        let tag: FinderTag
        let remove: Bool
    }

    struct EditTarget {
        let items: [FileItem]
        let host: MetadataMenuHost
    }

    struct DefaultAppChoice {
        let typeID: String
        let kindName: String
        let app: URL?
    }

    struct ColorChoice {
        let urls: [URL]
        let color: FileColor?
    }

    struct FilterChoice {
        let model: DirectoryViewModel
        let name: String
    }

    private weak var coordinator: FileOpsCoordinator?

    init(coordinator: FileOpsCoordinator) {
        self.coordinator = coordinator
    }

    @objc func toggleTag(_ sender: NSMenuItem) {
        guard let toggle = sender.representedObject as? TagToggle else { return }
        let edit: MetadataEdit = toggle.remove
            ? .tags(add: [], remove: [toggle.tag.name])
            : .tags(add: [toggle.tag], remove: [])
        coordinator?.applyMetadata(edit, to: toggle.urls, actionName: L10n.t("undo.tags"))
    }

    @objc func editTagsFromMenu(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? EditTarget else { return }
        editTags(of: target.items, host: target.host)
    }

    /// Opens the picker on the selection. Reads current tags from disk first: the picker edits them, so they must be exact,
    /// and a selection that cannot be read is reported rather than shown as untagged.
    func editTags(of items: [FileItem], host: MetadataMenuHost) {
        guard let coordinator, !items.isEmpty else { NSSound.beep(); return }
        let window = coordinator.grid?.view.window
        var lists: [[FinderTag]] = []
        for item in items {
            do {
                lists.append(try Engines.metadata.tags(of: item.url))
            } catch {
                Toast.show(error.localizedDescription, in: window)
                return
            }
        }
        guard let window else { return }
        let state = TagPickerState(selection: lists, known: MetadataMenu.offeredTags(host: host, extra: []))
        let title = items.count == 1 ? L10n.f("tags.picker.titleOne", items[0].name)
                                     : L10n.f("tags.picker.titleN", items.count)
        let urls = items.map(\.url)
        TagPickerSheet.present(state: state, title: title, in: window) { [weak self] final in
            guard let edit = final.edit else { return }
            Preferences.rememberTags(final.newTags)
            self?.coordinator?.applyMetadata(edit, to: urls, actionName: L10n.t("undo.tags"))
        }
    }

    @objc func editCommentFromMenu(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? EditTarget else { return }
        editComment(of: target.items)
    }

    /// Opens the comment editor. As with tags, current values come from disk, and anything unreadable stops here.
    func editComment(of items: [FileItem]) {
        guard let coordinator, !items.isEmpty else { NSSound.beep(); return }
        let window = coordinator.grid?.view.window
        var comments: [String] = []
        for item in items {
            do {
                comments.append(try Engines.metadata.comment(of: item.url) ?? "")
            } catch {
                Toast.show(error.localizedDescription, in: window)
                return
            }
        }
        guard let window else { return }
        let start = CommentEditStart(comments: comments)
        let title = items.count == 1 ? L10n.f("comment.titleOne", items[0].name)
                                     : L10n.f("comment.titleN", items.count)
        let urls = items.map(\.url)
        CommentSheet.present(start: start, title: title, in: window) { [weak self] text in
            self?.coordinator?.applyMetadata(.comment(text), to: urls, actionName: L10n.t("undo.comment"))
        }
    }

    @objc func chooseDefaultApp(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? DefaultAppChoice, let app = choice.app else { return }
        coordinator?.confirmDefaultApp(typeID: choice.typeID, kindName: choice.kindName, app: app)
    }

    @objc func chooseOtherDefaultApp(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? DefaultAppChoice else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let app = panel.url else { return }
        coordinator?.confirmDefaultApp(typeID: choice.typeID, kindName: choice.kindName, app: app)
    }

    nonisolated static func isFolder(_ item: FileItem) -> Bool { item.isDirectory && !item.isPackage }

    @objc func editFolderIconFromMenu(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? EditTarget else { return }
        editFolderIcon(of: target.items)
    }

    func editFolderIcon(of items: [FileItem]) {
        let folders = items.filter(Self.isFolder)
        guard let window = coordinator?.grid?.view.window, !folders.isEmpty else { NSSound.beep(); return }
        let title = folders.count == 1 ? L10n.f("folderIcon.titleOne", folders[0].name)
                                       : L10n.f("folderIcon.titleN", folders.count)
        let urls = folders.map(\.url)
        FolderIconSheet.present(title: title, in: window) { [weak self] spec in
            self?.coordinator?.applyMetadata(.folderIcon(spec), to: urls, actionName: L10n.t("undo.folderIcon"))
        }
    }

    @objc func removeFolderIcon(_ sender: NSMenuItem) {
        guard let urls = sender.representedObject as? [URL] else { return }
        coordinator?.applyMetadata(.folderIcon(nil), to: urls, actionName: L10n.t("undo.folderIcon"))
    }

    @objc func setFileColor(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? ColorChoice else { return }
        coordinator?.applyMetadata(.color(choice.color), to: choice.urls, actionName: L10n.t("undo.fileColor"))
    }

    @objc func toggleFilter(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? FilterChoice else { return }
        var names = choice.model.tagFilter
        if let existing = names.first(where: { TagQuery.sameName($0, choice.name) }) {
            names.remove(existing)
        } else {
            names.insert(choice.name)
        }
        choice.model.setTagFilter(names)
    }

    @objc func toggleTagSort(_ sender: NSMenuItem) {
        guard let model = sender.representedObject as? DirectoryViewModel else { return }
        model.setTagSort(ascending: model.tagSortAscending == nil ? true : nil)
    }
}
