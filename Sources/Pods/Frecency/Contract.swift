import Foundation
import HSpaceContracts

// Frecency pod's sole public contract surface (Axiom 3): vocabulary of usage-habit learning sort (frecency + match quality fusion).
// frecency = frequency (open count) × recency (exponential decay): search sorts by this automatically (M28, Listary style).

public struct FrecencyError: ClassifiedError, LocalizedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String
    /// What `localizedDescription` gives on `any Error`, which is how the app receives it
    public var errorDescription: String? { localizedDescription }

    init(_ cls: ErrorClass, _ message: String) {
        self.errorClass = cls
        self.localizedDescription = message
    }
}

/// One ledger entry: cumulative open count of a path + last open time.
public struct FrecencyEntry: Sendable, Hashable, Codable {
    public var count: Int
    public var lastAccess: Date

    public init(count: Int, lastAccess: Date) {
        self.count = count
        self.lastAccess = lastAccess
    }
}

/// Pure logic of usage-habit sort (stateless, thread-agnostic): match quality scoring + fusion with frecency.
/// Decoupled from [[FrecencyStore]]: the Store handles persistence and decay, Ranking handles "how high this hit ranks".
public enum SearchRanking {
    /// frecency decay: `count × 0.5^(ageDays / halfLifeDays)` (default half-life 30 days).
    /// One open a week ago ≈ 0.85; 30 days ago = 0.5; a year ago is nearly 0.
    public static func frecencyScore(_ e: FrecencyEntry, now: Date, halfLifeDays: Double = 30) -> Double {
        let ageDays = max(0, now.timeIntervalSince(e.lastAccess) / 86_400)
        return Double(e.count) * pow(0.5, ageDays / halfLifeDays)
    }

    /// Match quality tiers (higher is better; nil when nothing matches at all):
    /// exact name > name prefix > name word boundary > name substring > path substring > name subsequence (abbreviation) > path subsequence.
    /// Modelled on fzf/fzy: word-start and consecutive hits are weighted. Case-insensitive, but **within a tier case-matching hits rank first** (see caseBonus).
    ///
    /// The query is split on whitespace, **every term must match** (any term with no match → nil), and the score is the average across terms.
    /// Otherwise a query with spaces always gets nil here: the whole string `"override md"` is neither a substring
    /// nor a subsequence of `override.md` (the name has no space), so what the search engine had just learned to find would be
    /// scored 0 here and sink to the bottom. Both layers must use the same rule.
    public static func matchScore(query: String, name: String, path: String) -> Double? {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return nil }
        var total = 0.0
        for t in terms {
            guard let s = termScore(term: t, name: name, path: path) else { return nil }
            total += s
        }
        return total / Double(terms.count)
    }

    /// Match quality of a single term (same tiers as above).
    private static func termScore(term: String, name: String, path: String) -> Double? {
        let q = term.lowercased()
        guard !q.isEmpty else { return nil }
        let n = name.lowercased()
        let p = path.lowercased()

        // Case-match bonus: granted when the term can be found **verbatim** (case-sensitively) in the name.
        // Capped at 50, **less than the gap between any two tiers** (smallest gap 200): it only orders within a tier
        // and never lets a weak match jump a strong one because its case happens to agree.
        // User request: "show case-matching results first, then those with the same characters but different case".
        let bonus: Double = name.contains(term) ? 50 : 0

        if n == q { return 1000 + bonus }
        if n.hasPrefix(q) { return 800 + bonus }
        if let r = n.range(of: q) {
            // Name substring: if the preceding character is a separator → word boundary (stronger); otherwise plain substring (light position penalty)
            let idx = n.distance(from: n.startIndex, to: r.lowerBound)
            let atWordStart = idx == 0 || isSeparator(n[n.index(r.lowerBound, offsetBy: -1)])
            return (atWordStart ? 600 : 400) - Double(min(idx, 50)) + bonus
        }
        if p.contains(q) { return 200 + bonus }
        if let sub = subsequenceScore(query: q, in: n) { return 100 + sub }   // abbreviation/fuzzy (name)
        if let sub = subsequenceScore(query: q, in: p) { return 50 + sub }    // abbreviation/fuzzy (path)
        return nil
    }

    /// Fusion: `match + frecencyWeight(queryLen) × log(1+frecency)`.
    /// Weight shrinks as the query grows: short queries rely on habit, long queries on match quality (observed Listary behaviour).
    public static func fused(match: Double, frecency: Double, queryLen: Int) -> Double {
        let w: Double = queryLen <= 2 ? 400 : (queryLen <= 4 ? 200 : 100)
        return match + w * log(1 + max(0, frecency))
    }

    // MARK: Private

    private static func isSeparator(_ c: Character) -> Bool {
        c == " " || c == "-" || c == "_" || c == "." || c == "/" || c == "("
    }

    /// Subsequence match (query's characters appear in order in text); consecutive hits score extra. Returns nil on no match.
    private static func subsequenceScore(query: String, in text: String) -> Double? {
        var qi = query.startIndex
        var consecutive = 0, bestRun = 0, run = 0
        var lastMatched = false
        for ch in text {
            if qi < query.endIndex, ch == query[qi] {
                qi = query.index(after: qi)
                if lastMatched { run += 1; bestRun = max(bestRun, run) } else { run = 0 }
                lastMatched = true
                consecutive += 1
            } else {
                lastMatched = false
            }
        }
        guard qi == query.endIndex else { return nil }   // query not fully covered
        return Double(bestRun) * 5   // the longer the consecutive run, the more it looks like "really typing this word"
    }
}
