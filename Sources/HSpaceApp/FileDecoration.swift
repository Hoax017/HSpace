import AppKit
import HSpaceContracts
import FileMetadata

/// App-side copy of the metadata settings. Cells read it synchronously, so it cannot live behind the store's actor.
@MainActor
enum MetadataSettings {
    private(set) static var colorRules: [ColorRule] = []
    private static var store: MetadataStore?

    static func load(from store: MetadataStore) async {
        self.store = store
        colorRules = await store.colorRules()
        announce()
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

    init(_ item: FileItem, _ metadata: ItemMetadata?) {
        tags = metadata?.tags ?? []
        tint = ColorRules.color(for: item, metadata: metadata, rules: MetadataSettings.colorRules, now: Date())
            .map(FileColorPalette.color)
    }
}

/// File colours as system colours (the Zero-Hex rule: light and dark resolve by themselves)
@MainActor
enum FileColorPalette {
    static func color(_ file: FileColor) -> NSColor {
        switch file {
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .teal: return .systemTeal
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .pink: return .systemPink
        case .gray: return .systemGray
        }
    }

    static func name(_ file: FileColor) -> String {
        L10n.t("fileColor.\(file.rawValue)")
    }

    static func menuImage(_ file: FileColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            .applying(.init(paletteColors: [color(file)]))
        return NSImage.officialSymbol("circle.fill")?.withSymbolConfiguration(config)
    }
}
