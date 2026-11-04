import AppKit
import UniformTypeIdentifiers
import HSpaceContracts

/// Display formatters, all cached and reused (DateFormatter/ByteCountFormatter are expensive to construct);
/// kind strings and icons are cached per UTType (zero repeated work when scrolling directories of tens of thousands)
@MainActor
enum Formatters {
    /// List/cell font size (appearance setting; reads Preferences.listFontSize). Changes are applied through the column rebuild path
    static var listFontSize: CGFloat { CGFloat(Preferences.listFontSize) }

    /// Relative date display (M29): today/yesterday → "Today 22:57"; this year → year omitted, "Aug 24, 22:57";
    /// other years only → with year, "Aug 24, 2025, 22:57". `now` is injectable for deterministic tests.
    /// Follows Finder: the list column and Get Info both use the relative form, omitting the current year (owner request 2026-08-27).
    static func relativeDate(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) {
            return L10n.t("date.today") + " " + timeOnly.string(from: date)
        }
        if let yst = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: yst) {
            return L10n.t("date.yesterday") + " " + timeOnly.string(from: date)
        }
        if cal.isDate(date, equalTo: now, toGranularity: .year) {
            return sameYearDateTime.string(from: date)
        }
        return otherYearDateTime.string(from: date)
    }

    /// Time only, "22:57", appended after the today/yesterday prefix (`j` picks 12/24-hour from the locale)
    private static let timeOnly: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()

    /// Date in the current year, e.g. "Aug 24, 10:57 PM": no year
    private static let sameYearDateTime: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMdjmm")
        return f
    }()

    /// Date in another year, e.g. "Aug 24, 2025, 22:57": with year
    private static let otherYearDateTime: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("yMMMdjmm")
        return f
    }()

    static let size: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    /// Splits a size string into (value, unit) for the three-tier ink of the size column (value labelColor / unit secondaryLabelColor).
    /// Splits at the last space; with no space (rare) the whole string is the value and the unit is empty.
    static func sizeParts(fromByteCount bytes: Int64) -> (value: String, unit: String) {
        let s = size.string(fromByteCount: bytes)
        if let r = s.range(of: " ", options: .backwards) {
            return (String(s[..<r.lowerBound]), String(s[r.upperBound...]))
        }
        return (s, "")
    }

    private static var kindCache: [String: String] = [:]
    private static var iconCache: [String: NSImage] = [:]
    private static var fullIconCache: [String: NSImage] = [:]

    static func kind(forTypeID id: String?, isDirectory: Bool) -> String {
        guard let id else { return isDirectory ? L10n.t("kind.folder") : L10n.t("kind.document") }
        if let cached = kindCache[id] { return cached }
        let name = UTType(id)?.localizedDescription
            ?? (isDirectory ? L10n.t("kind.folder") : L10n.t("kind.document"))
        kindCache[id] = name
        return name
    }

    /// Two icon paths: ordinary files use the generic UTType icon (fast synchronous path, cached per type);
    /// packages/apps (.app etc) keep their real icon inside the bundle and must be read by file path or they show blank; cached per path
    static func icon(for item: FileItem) -> NSImage {
        if item.isPackage {
            let key = "path:" + item.url.path
            if let cached = iconCache[key] { return cached }
            let image = NSWorkspace.shared.icon(forFile: item.url.path)
            image.size = NSSize(width: 16, height: 16)
            iconCache[key] = image
            return image
        }
        let key = item.contentTypeID ?? (item.isDirectory ? "public.folder" : "public.data")
        if let cached = iconCache[key] { return cached }
        let type = UTType(key) ?? (item.isDirectory ? .folder : .data)
        let image = NSWorkspace.shared.icon(for: type)
        image.size = NSSize(width: 16, height: 16)
        iconCache[key] = image
        return image
    }

    /// Large icon (for the icon grid and column preview): keeps the system's multi-resolution representations, size untouched.
    /// Cached separately from the 16pt list icons (NSImage.size is shared mutable state; mixing them would inflate list icons); NSImageView scales as needed for display
    static func fullIcon(for item: FileItem) -> NSImage {
        let key: String = item.isPackage
            ? "path:" + item.url.path
            : (item.contentTypeID ?? (item.isDirectory ? "public.folder" : "public.data"))
        if let cached = fullIconCache[key] { return cached }
        let image: NSImage = item.isPackage
            ? NSWorkspace.shared.icon(forFile: item.url.path)
            : NSWorkspace.shared.icon(for: UTType(key) ?? (item.isDirectory ? .folder : .data))
        fullIconCache[key] = image
        return image
    }
}
