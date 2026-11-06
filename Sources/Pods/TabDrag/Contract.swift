import Foundation

// TabDrag pod's sole public contract surface (Axiom 3): where a dragged tab lands and what a drag amounts to.
// A gap is a place between tabs: gap 0 is before the first tab, gap n after the last.

public enum TabMove {
    /// The gap nearest to `x`, given each tab's left and right edge
    public static func gap(at x: Double, edges: [(min: Double, max: Double)]) -> Int {
        edges.firstIndex { x < ($0.min + $0.max) / 2 } ?? edges.count
    }

    /// The tab's index after dropping it in `gap`; nil when it would not move
    public static func destination(from index: Int, gap: Int, count: Int) -> Int? {
        guard index >= 0, index < count, gap >= 0, gap <= count else { return nil }
        let target = gap > index ? gap - 1 : gap
        return target == index ? nil : target
    }

    /// Where the tab now at `position` ends up when the tab at `from` moves to `to`
    public static func moved(_ position: Int, from: Int, to: Int) -> Int {
        if position == from { return to }
        if from < position, position <= to { return position - 1 }
        if to <= position, position < from { return position + 1 }
        return position
    }
}

/// How a drag ended, as far as the tab strip that started it can tell
public struct TabDragEnd: Sendable, Equatable {
    /// A tab strip took the drop
    public var accepted: Bool
    /// The button is still down: Esc ended the drag
    public var cancelled: Bool
    /// The drop point lies on the window the tab came from
    public var insideSourceWindow: Bool
    public var tabCount: Int

    public init(accepted: Bool, cancelled: Bool, insideSourceWindow: Bool, tabCount: Int) {
        self.accepted = accepted
        self.cancelled = cancelled
        self.insideSourceWindow = insideSourceWindow
        self.tabCount = tabCount
    }

    /// Dropped clear of its window, and something stays behind: the tab gets a window of its own
    public var detaches: Bool {
        !accepted && !cancelled && !insideSourceWindow && tabCount > 1
    }
}

/// What travels on the drag pasteboard
public struct TabDragPayload: Sendable, Codable, Equatable {
    public static let pasteboardType = "com.hoax017.hspace.workspace-tab"

    public let windowNumber: Int
    public let index: Int

    public init(windowNumber: Int, index: Int) {
        self.windowNumber = windowNumber
        self.index = index
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }

    /// nil for anything that is not a payload
    public static func decoded(_ data: Data) -> TabDragPayload? {
        do {
            return try JSONDecoder().decode(TabDragPayload.self, from: data)
        } catch {
            return nil
        }
    }
}
