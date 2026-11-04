import Foundation
import HSpaceContracts

// SearchEngine pod's sole public contract surface (Axiom 3): request/hit vocabulary of focused search

public enum SearchLimits {
    /// Hard result cap per search: global Spotlight (NSMetadataQueryLocalComputerScope) hits hundreds of thousands on common words,
    /// and reading every result(at:) on the main thread into an NSTableView without a cap freezes the app and spikes CPU. Both channels stop at the cap.
    /// The UI then shows "Showing the first N results, refine your search". 2000 is enough to locate a single file and keeps main-thread cost bounded.
    public static let maxResults = 2000

    /// Slots reserved for channel B (hidden file scan) while channel A can still read.
    ///
    /// Real failing case: channel A can read a full 2000 in the first gathering notification (0.3s); `append()` then hits
    /// `keptCount >= maxResults` → `flushNow(); teardown()` → `scanTask.cancel()`, and the batch channel B
    /// holds on its stack at that moment is discarded. So for any query with ≥2000 Spotlight hits,
    /// "Include hidden files" is a **silent no-op switch**: another independent trigger of "visible but unsearchable".
    /// With the reserve, channel A takes at most maxResults - scanReserve and channel B always has room to land.
    public static let scanReserve = 500

    /// Channel A's read budget for one drain (pure function: deterministic in unit tests, no dependence on Spotlight index state)
    public static func spotlightReadBudget(kept: Int, scanAlive: Bool) -> Int {
        max(0, maxResults - kept - (scanAlive ? scanReserve : 0))
    }
}

public struct SearchRequest: Sendable {
    public enum Scope: Sendable {
        case global
        case directory(URL)
    }

    public let query: String
    public let scope: Scope
    /// Search by name (channel A Spotlight kMDItemFSName + channel B file name scan)
    public let searchNames: Bool
    /// Full-text content search (channel A Spotlight kMDItemTextContent only: a full-text index cannot be self-built, honest degradation)
    public let searchContents: Bool
    /// Hidden files channel switch (goes beyond Spotlight: index-independent, does not skip hidden files, name search only)
    public let includeHidden: Bool
    /// Heavy directory names skipped by channel B's recursive scan (configurable)
    public let skippedDirectoryNames: Set<String>

    public init(query: String, scope: Scope,
                searchNames: Bool = true, searchContents: Bool = false,
                includeHidden: Bool = false,
                skippedDirectoryNames: Set<String> = ["node_modules", ".git", ".Trash", "Library"]) {
        self.query = query
        self.scope = scope
        self.searchNames = searchNames
        self.searchContents = searchContents
        self.includeHidden = includeHidden
        self.skippedDirectoryNames = skippedDirectoryNames
    }
}

/// Search hit (display attributes fetched at build time, the UI needs no extra stat)
public struct SearchHit: Sendable, Hashable {
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let size: Int64?
    public let modified: Date?
    /// UTType.identifier (the UI filters kinds by conformance)
    public let contentTypeID: String?

    public init(url: URL, name: String, isDirectory: Bool,
                size: Int64?, modified: Date?, contentTypeID: String?) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.contentTypeID = contentTypeID
    }
}

/// Query terms: splits input on whitespace and matches term by term, order-independent, case- and diacritic-insensitive.
///
/// User report: searching `override md` in `~/.claude` reported "not found" even though `OVERRIDE.md` was right there.
/// Case was not the cause (both channels already used `localizedCaseInsensitiveContains` / `CONTAINS[cd]`,
/// and `override` alone was measured to hit): the real culprit was the **space**: the whole string `"override md"` was looked up as one
/// contiguous substring, while that position in the file name is a dot. `md override` failing too confirms this.
///
/// Pure function, stateless: both channels share the same rule, which is also what makes it verifiable (in the whole-string era that check was scattered in scan loops).
public enum QueryTerms {
    /// Splits into terms. Runs of whitespace collapse, leading/trailing whitespace is dropped; an empty query yields an empty array.
    public static func split(_ query: String) -> [String] {
        query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Matches when every term appears in `name` (AND, order-independent, case/diacritic-insensitive).
    /// An empty term list never matches: otherwise an empty query would return the whole disk.
    public static func matches(_ name: String, terms: [String]) -> Bool {
        guard !terms.isEmpty else { return false }
        return terms.allSatisfy { name.localizedCaseInsensitiveContains($0) }
    }
}

public struct SearchError: ClassifiedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String

    init(_ cls: ErrorClass, _ message: String) {
        self.errorClass = cls
        self.localizedDescription = message
    }
}
