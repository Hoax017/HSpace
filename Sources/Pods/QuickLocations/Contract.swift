import Foundation

// QuickLocations pod's sole public contract surface (Axiom 3): the list behind the quick locations panel.
// The app supplies bookmarks, volumes and usage; this pod merges, filters and checks them. Match scoring is injected,
// so the panel ranks exactly as focused search does without the two pods knowing each other (BG-11).

public enum QuickLocationKind: String, Sendable, Equatable {
    case bookmark, place, volume, recent, typed
}

public struct QuickLocation: Sendable, Equatable, Identifiable {
    public let kind: QuickLocationKind
    public let title: String
    public let path: String
    /// How much the owner uses it; 0 when unknown
    public let habit: Double

    public var id: String { path }

    public init(kind: QuickLocationKind, title: String, path: String, habit: Double = 0) {
        self.kind = kind
        self.title = title
        self.path = QuickLocationList.normalized(path)
        self.habit = habit
    }
}

public enum QuickLocationStatus: Sendable, Equatable {
    case folder, file, missing
}

public enum QuickLocationList {
    /// Scores a query against a name and a path; nil when it does not match
    public typealias Match = @Sendable (_ query: String, _ name: String, _ path: String) -> Double?

    /// How many recent folders are checked and offered
    public static let recentLimit = 64

    /// Places that wake an automounter: checking them can hang for minutes
    private static let automounted = ["/net/", "/home/", "/Network/"]

    /// Later lists only add what earlier ones lack, so a bookmarked folder is never repeated as a recent one
    public static func merge(_ lists: [QuickLocation]...) -> [QuickLocation] {
        var seen = Set<String>()
        return lists.joined().filter { seen.insert($0.path).inserted }
    }

    /// The most used paths, most used first. Equal scores order by path, so the list does not shuffle.
    public static func topPaths(_ scores: [String: Double], limit: Int = recentLimit) -> [String] {
        scores.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(max(0, limit)).map(\.key)
    }

    /// An empty query keeps the given order. Otherwise best match first, with habit as a small push;
    /// a tie keeps the given order, so bookmarks stay above volumes and recent folders.
    public static func filter(_ all: [QuickLocation], query: String, match: Match) -> [QuickLocation] {
        let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return all }
        let scored: [(index: Int, score: Double, item: QuickLocation)] = all.enumerated().compactMap { index, item in
            guard let score = match(wanted, item.title, item.path) else { return nil }
            return (index, score + 40 * log(1 + max(0, item.habit)), item)
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }.map(\.item)
    }

    /// The path meant when the query is written as one: absolute or from the home folder
    public static func typedPath(_ query: String, home: URL) -> String? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "~" { return normalized(home.path) }
        if text.hasPrefix("~/") { return normalized(home.path + "/" + text.dropFirst(2)) }
        return text.hasPrefix("/") ? normalized(text) : nil
    }

    /// Only what is a folder right now, in the given order. Packages count as files, and whatever cannot be read is left out.
    /// Touches the disk: never on the main actor.
    public static func existingFolders(_ paths: [String]) async -> [String] {
        var kept: [String] = []
        for path in paths where !isAutomounted(path) {
            if Task.isCancelled { break }
            if await status(of: path) == .folder { kept.append(path) }
        }
        return kept
    }

    /// Touches the disk: never on the main actor.
    public static func status(of path: String) async -> QuickLocationStatus {
        do {
            let values = try URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return values.isDirectory == true && values.isPackage != true ? .folder : .file
        } catch {
            return .missing
        }
    }

    static func normalized(_ path: String) -> String {
        let clean = URL(fileURLWithPath: path).standardizedFileURL.path
        return clean.count > 1 && clean.hasSuffix("/") ? String(clean.dropLast()) : clean
    }

    private static func isAutomounted(_ path: String) -> Bool {
        automounted.contains { path.hasPrefix($0) }
    }
}
