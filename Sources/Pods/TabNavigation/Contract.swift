import Foundation

// TabNavigation pod's sole public contract surface (Axiom 3): which tabs were used last, and stepping through them.
// Tabs are plain indexes: the app owns what they hold.

/// Tabs by last use. It may hold fewer tabs than exist: a restored session only knows its active tab.
public struct TabRecency: Sendable, Equatable {
    /// Most recent first
    public private(set) var order: [Int]

    public init(active: Int) {
        order = [active]
    }

    public var mostRecent: Int? { order.first }

    public mutating func touch(_ index: Int) {
        order.removeAll { $0 == index }
        order.insert(index, at: 0)
    }

    /// The tab at `index` is gone: later tabs shift down by one
    public mutating func remove(at index: Int) {
        order = order.compactMap { $0 == index ? nil : ($0 > index ? $0 - 1 : $0) }
    }

    /// The first `count` tabs are gone
    public mutating func removeFirst(_ count: Int) {
        order = order.compactMap { $0 >= count ? $0 - count : nil }
    }

    /// Every tab: used ones by recency, then the rest in tab order
    public func all(count: Int) -> [Int] {
        let known = order.filter { $0 >= 0 && $0 < count }
        return known + (0..<count).filter { !known.contains($0) }
    }
}

/// One use of the switcher. Like the system's app switcher it starts on the tab before the current one,
/// so a single press and release swaps the last two tabs.
public struct TabSwitcherSession: Sendable, Equatable {
    /// Most recent first; the first is the current tab
    public let tabs: [Int]
    public private(set) var position: Int

    /// nil when there is nowhere to switch to
    public init?(tabs: [Int], backward: Bool = false) {
        guard tabs.count > 1 else { return nil }
        self.tabs = tabs
        position = backward ? tabs.count - 1 : 1
    }

    public var selected: Int { tabs[position] }

    /// Wraps at both ends
    public mutating func step(backward: Bool) {
        position = (position + (backward ? -1 : 1) + tabs.count) % tabs.count
    }

    /// Picks a row directly. Out of range is ignored.
    public mutating func select(position wanted: Int) {
        guard tabs.indices.contains(wanted) else { return }
        position = wanted
    }
}
