import Foundation
import HSpaceContracts

// ContextMenuLayout pod's sole public contract surface (Axiom 3): which context menu entries the owner hides, and the
// order they come in. Entries are string ids grouped in sections (the separators of the menu). No AppKit here: the app
// tags its menu items with the ids and rebuilds the menu from what this returns.

/// The owner's choices for one context menu. Ids stay strings, so a stored layout survives an app that no longer has one
/// of its entries, or has a new one.
public struct ContextMenuSettings: Sendable, Equatable {
    /// Entries left out of the menu. Sorted and free of repeats.
    public private(set) var hidden: [String]
    /// Entries in the owner's order, across sections. An entry missing here keeps its default place after the ordered ones.
    public private(set) var order: [String]

    public init(hidden: [String] = [], order: [String] = []) {
        self.hidden = Array(Set(hidden)).sorted()
        var seen = Set<String>()
        self.order = order.filter { seen.insert($0).inserted }
    }

    public var isDefault: Bool { hidden.isEmpty && order.isEmpty }

    public func isHidden(_ id: String) -> Bool { hidden.contains(id) }

    /// Every entry of `sections`, hidden or not, in the owner's order. Entries never leave their section,
    /// so the menu keeps its groups. An entry the stored order does not name goes after the ones it does, in default order.
    public func ordered(_ sections: [[String]]) -> [[String]] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return sections.map { section in
            let ranked = section.filter { rank[$0] != nil }.sorted { rank[$0]! < rank[$1]! }
            return ranked + section.filter { rank[$0] == nil }
        }
    }

    /// What the menu shows: the owner's order without hidden entries. Sections left empty are dropped, so no two
    /// separators ever meet.
    public func arranged(_ sections: [[String]]) -> [[String]] {
        ordered(sections)
            .map { $0.filter { !isHidden($0) } }
            .filter { !$0.isEmpty }
    }

    public mutating func setHidden(_ id: String, _ hide: Bool) {
        guard hide != isHidden(id) else { return }
        hidden = hide ? (hidden + [id]).sorted() : hidden.filter { $0 != id }
    }

    /// Moves an entry by `offset` places within its own section of `sections`. Past either end it stops there.
    /// An id that is in no section changes nothing.
    public mutating func move(_ id: String, by offset: Int, in sections: [[String]]) {
        var all = ordered(sections)
        guard let s = all.firstIndex(where: { $0.contains(id) }), let from = all[s].firstIndex(of: id) else { return }
        let to = min(max(0, from + offset), all[s].count - 1)
        guard to != from else { return }
        all[s].remove(at: from)
        all[s].insert(id, at: to)
        // The whole arrangement is written down: ids the app no longer has are kept, so they come back in place if it does again
        let shown = Set(all.joined())
        order = Array(all.joined()) + order.filter { !shown.contains($0) }
    }
}
