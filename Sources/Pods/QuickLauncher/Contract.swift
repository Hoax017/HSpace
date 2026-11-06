import Foundation
import HSpaceContracts

// QuickLauncher pod's sole public contract surface (Axiom 3): what the quick launcher offers for a query, and which commands
// the owner used last. The app turns its menus and locations into entries; match scoring is injected (BG-11).

public struct LauncherError: ClassifiedError, LocalizedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String
    /// What `localizedDescription` gives on `any Error`, which is how the app receives it
    public var errorDescription: String? { localizedDescription }

    init(_ cls: ErrorClass, _ message: String) {
        self.errorClass = cls
        self.localizedDescription = message
    }
}

public struct LauncherEntry: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case command, location
    }

    public let id: String
    public let kind: Kind
    public let title: String
    /// Where it comes from: a menu path or a folder path
    public let detail: String

    public init(id: String, kind: Kind, title: String, detail: String) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
    }
}

/// `>` at the start narrows the launcher to commands
public struct LauncherQuery: Sendable, Equatable {
    public let text: String
    public let commandsOnly: Bool

    public init(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        commandsOnly = trimmed.hasPrefix(">")
        text = commandsOnly ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces) : trimmed
    }
}

public enum LauncherRanking {
    public typealias Match = @Sendable (_ query: String, _ title: String, _ detail: String) -> Double?

    /// Most rows a query gives: the panel is for picking, not browsing
    public static let limit = 50

    /// An empty query offers commands used lately, then the rest as given. Otherwise best match first; a recently used
    /// command wins between equal matches but never beats a clearly better one.
    public static func rank(_ entries: [LauncherEntry], query: LauncherQuery, recent: [String], match: Match) -> [LauncherEntry] {
        let wanted = query.commandsOnly ? entries.filter { $0.kind == .command } : entries
        let position = Dictionary(recent.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        guard !query.text.isEmpty else {
            let used = wanted.filter { position[$0.id] != nil }.sorted { position[$0.id, default: 0] < position[$1.id, default: 0] }
            return Array((used + wanted.filter { position[$0.id] == nil }).prefix(limit))
        }
        let scored: [(index: Int, score: Double, entry: LauncherEntry)] = wanted.enumerated().compactMap { index, entry in
            guard let score = match(query.text, entry.title, entry.detail) else { return nil }
            let boost = position[entry.id].map { 30 - min(Double($0), 20) } ?? 0
            return (index, score + boost, entry)
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }.prefix(limit).map(\.entry)
    }
}

/// Commands the owner ran, most recent first. Reads memory only; a run writes the file.
public protocol CommandHistoryStoring: Sendable {
    func recent() -> [String]
    func record(_ id: String) throws
    func takeProblem() -> LauncherError?
}
