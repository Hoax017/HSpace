import AppKit
import HSpaceContracts
import FileMetadata

/// App-side copy of the metadata settings. Cells read it synchronously, so it cannot live behind the store's actor.
@MainActor
enum MetadataSettings {
    private(set) static var colorRules: [ColorRule] = []
    private(set) static var kindGroups = KindGroups.defaults(localized: { L10n.t($0) })
    private static var store: MetadataStore?

    static func load(from store: MetadataStore) async {
        self.store = store
        colorRules = await store.colorRules()
        if let saved = await store.kindGroups() { kindGroups = saved }
        announce()
        NotificationCenter.default.post(name: .hspaceGroupingChanged, object: nil)
    }

    /// Returns what went wrong. The rules in use change only when the store took them.
    static func setColorRules(_ rules: [ColorRule]) async -> String? {
        guard let store else { return nil }
        do {
            try await store.setColorRules(rules)
        } catch {
            return error.localizedDescription
        }
        colorRules = rules
        announce()
        return nil
    }

    /// Returns what went wrong. The groups in use change only when the store took them.
    static func setKindGroups(_ groups: [KindGroup]) async -> String? {
        guard let store else { return nil }
        do {
            try await store.setKindGroups(groups)
        } catch {
            return error.localizedDescription
        }
        kindGroups = groups
        NotificationCenter.default.post(name: .hspaceGroupingChanged, object: nil)
        return nil
    }

    private static func announce() {
        NotificationCenter.default.post(name: .hspaceFileColorsChanged, object: nil)
    }
}

extension Notification.Name {
    /// Colour rules changed: visible rows recolour in place
    static let hspaceFileColorsChanged = Notification.Name("hspaceFileColorsChanged")
}

/// How one item is dressed in a view. Built only for rows on screen.
@MainActor
struct FileDecoration {
    let tags: [FinderTag]
    let tint: NSColor?
    /// A folder's icon, custom or not, so a removed custom icon gives way. nil for anything else, which keeps its own icon path.
    let icon: NSImage?

    init(_ item: FileItem, _ metadata: ItemMetadata?, largeIcon: Bool = false) {
        tags = metadata?.tags ?? []
        if !item.isDirectory || item.isPackage {
            icon = nil
        } else if metadata?.hasCustomIcon == true {
            icon = Formatters.customIcon(for: item)
        } else {
            icon = largeIcon ? Formatters.fullIcon(for: item) : Formatters.icon(for: item)
        }
        tint = ColorRules.color(for: item, metadata: metadata, rules: MetadataSettings.colorRules, now: Date())
            .map(FileColorPalette.color)
    }
}

/// File colours as system colours (the Zero-Hex rule: light and dark resolve by themselves)
@MainActor
enum FileColorPalette {
    static func color(_ file: FileColor) -> NSColor { file.systemColor }

    static func name(_ file: FileColor) -> String {
        L10n.t("fileColor.\(file.rawValue)")
    }

    static func menuImage(_ file: FileColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            .applying(.init(paletteColors: [color(file)]))
        return NSImage.officialSymbol("circle.fill")?.withSymbolConfiguration(config)
    }
}
