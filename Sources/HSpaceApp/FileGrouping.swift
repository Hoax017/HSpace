import Foundation
import HSpaceContracts
import FileMetadata

/// Pure logic for time-based grouping (M26): the single source of truth shared by the list and icon views.
/// Group key format, date selection and bucketing live here, so index arithmetic and key formats don't spread across views (BG).
@MainActor
enum FileGrouping {
    /// Whether this sort key is date-like (only date keys group)
    static func isDateKey(_ k: SortSpec.Key) -> Bool {
        k == .dateModified || k == .created || k == .added
    }

    /// Grouping is active when the preference is on and the sort key is date-like
    static func active(_ sort: SortSpec) -> Bool {
        Preferences.listGrouping && isDateKey(sort.key)
    }

    private static func date(for item: FileItem, key: SortSpec.Key) -> Date? {
        switch key {
        case .dateModified: return item.modified
        case .created: return item.created
        case .added: return item.added
        default: return nil
        }
    }

    /// Injection point for the current time (M29): production uses the real Date; tests inject a fixed clock to verify bucket placement deterministically.
    /// Same semantics as `now` in [[Formatters.relativeDate]] (centralized here so views don't each read Date).
    static var nowProvider: () -> Date = { Date() }

    /// Title formatter for prior years (localized); used only for buckets outside the current year
    private static func yearTitle(_ year: Int) -> String {
        String(format: L10n.t("group.year"), year)
    }

    /// Group key (stable across languages, used for collapse/filter bookkeeping) + group title (localized for display).
    /// Relative buckets (M29, owner request): today/yesterday/this week/this month/earlier this year/prior years (YYYY), nearest first.
    /// Key prefixes g0..g5 split prior years by year and let group order follow the sort direction (items are already date-sorted).
    static func keyTitle(for item: FileItem, key: SortSpec.Key) -> (key: String, title: String) {
        guard let date = date(for: item, key: key) else {
            return ("__nodate__", L10n.t("group.noDate"))
        }
        let cal = Calendar.current
        let now = nowProvider()
        if cal.isDate(date, inSameDayAs: now) {
            return ("g0-today", L10n.t("group.today"))
        }
        if let yst = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: yst) {
            return ("g1-yesterday", L10n.t("group.yesterday"))
        }
        if cal.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
            return ("g2-week", L10n.t("group.thisWeek"))
        }
        if cal.isDate(date, equalTo: now, toGranularity: .month) {
            return ("g3-month", L10n.t("group.thisMonth"))
        }
        if cal.isDate(date, equalTo: now, toGranularity: .year) {
            return ("g4-year-earlier", L10n.t("group.earlierThisYear"))
        }
        let year = cal.component(.year, from: date)
        return (String(format: "g5-%04d", year), yearTitle(year))
    }

    struct Group: Equatable {
        let key: String
        let title: String
        /// Indices of the group's items in the original items array (keeps their sorted relative order)
        let indices: [Int]
    }

    /// Recency rank of a relative bucket (newer is smaller): today 0 < yesterday 1 < this week 2 < this month 3 < earlier this year 4 < prior years (by year, newer is smaller) < no date.
    /// Groups are ordered by this (I-49), no longer by first appearance: "folders first" makes items=[folders][files], which isn't globally monotonic
    /// and would push file-only buckets (say "Today" holding a single file) behind the bucket order set up by folders.
    static func recencyRank(ofKey key: String) -> Int {
        switch key {
        case "g0-today": return 0
        case "g1-yesterday": return 1
        case "g2-week": return 2
        case "g3-month": return 3
        case "g4-year-earlier": return 4
        case "__nodate__": return Int.max
        default:
            if key.hasPrefix("g5-"), let y = Int(key.dropFirst(3)) { return 5 + (9999 - y) }
            return Int.max - 1
        }
    }

    /// Grouping for a model: by date or by kind group. A tag sort has its own order, which groups would break up
    static func active(_ model: DirectoryViewModel) -> Bool {
        guard model.tagSortAscending == nil else { return false }
        return active(model.sort) || (Preferences.listGrouping && model.sort.key == .kind)
    }

    /// The groups for what the model is sorted by
    static func groups(for model: DirectoryViewModel) -> [Group] {
        model.sort.key == .kind
            ? kindBuckets(model.items, groups: MetadataSettings.kindGroups, ascending: model.sort.ascending)
            : buckets(model.items, key: model.sort.key, ascending: model.sort.ascending)
    }

    /// Groups in the manager's order, reversed when descending. Items no group claims stay together at the end in both
    /// directions, and empty groups are left out. Pure, like `buckets`.
    static func kindBuckets(_ items: [FileItem], groups: [KindGroup], ascending: Bool) -> [Group] {
        var members = [[Int]](repeating: [], count: groups.count)
        var others: [Int] = []
        for (index, owner) in KindGroups.assign(items, to: groups).enumerated() {
            if let owner { members[owner].append(index) } else { others.append(index) }
        }
        var result = groups.indices.filter { !members[$0].isEmpty }.map {
            Group(key: "kind-\(groups[$0].id.uuidString)", title: groups[$0].name, indices: members[$0])
        }
        if !ascending { result.reverse() }
        if !others.isEmpty { result.append(Group(key: "kind-other", title: L10n.t("group.otherKinds"), indices: others)) }
        return result
    }

    /// Items already sorted by `sort` → ordered groups: **group order follows relative recency** (direction-aware, unaffected by foldersFirst);
    /// items keep their relative order inside a group (including folders first). Pure function, black-box testable.
    /// Date descending (newest first) → groups by ascending rank (today first); date ascending → descending rank (today last).
    static func buckets(_ items: [FileItem], key: SortSpec.Key, ascending: Bool) -> [Group] {
        var indexBuckets: [String: [Int]] = [:]
        var titles: [String: String] = [:]
        for (i, item) in items.enumerated() {
            let (gk, gt) = keyTitle(for: item, key: key)
            if indexBuckets[gk] == nil { indexBuckets[gk] = []; titles[gk] = gt }
            indexBuckets[gk]?.append(i)
        }
        let orderedKeys = indexBuckets.keys.sorted {
            let ra = recencyRank(ofKey: $0), rb = recencyRank(ofKey: $1)
            return ascending ? ra > rb : ra < rb
        }
        return orderedKeys.map { Group(key: $0, title: titles[$0] ?? $0, indices: indexBuckets[$0] ?? []) }
    }
}
