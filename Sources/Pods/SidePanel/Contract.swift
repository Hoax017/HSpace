import CoreGraphics
import Foundation
import HSpaceContracts

// SidePanel pod's sole public contract surface (Axiom 3): what the side panel shows for a selection, and which actions it offers.
// No AppKit here: the app draws the preview and turns action ids into commands.

/// What a selection comes to, for the preview
public enum PreviewSubject: Sendable, Equatable {
    case nothing
    case item(url: URL, name: String)
    /// `knownBytes` counts files only: a folder's size is not in a listing
    case several(count: Int, folders: Int, knownBytes: Int64)

    public init(selection: [FileItem]) {
        switch selection.count {
        case 0:
            self = .nothing
        case 1:
            self = .item(url: selection[0].url, name: selection[0].name)
        default:
            self = .several(count: selection.count,
                            folders: selection.filter { $0.isDirectory && !$0.isPackage }.count,
                            knownBytes: selection.reduce(0) { $0 + ($1.size ?? 0) })
        }
    }
}

/// The actions the panel offers, in the owner's order. Ids stay strings so that a stored list survives an app that
/// no longer knows one of them, or knows a new one.
public struct PanelActionList: Sendable, Equatable {
    /// Shown, in order
    public private(set) var enabled: [String]
    /// Every known action, in order, shown or not
    public private(set) var all: [String]

    /// - Parameters:
    ///   - stored: the ids the owner chose, or nil when never chosen
    ///   - known: every action the app has
    ///   - defaults: what a new owner gets
    /// Unknown and repeated stored ids are dropped. Actions added since stay off but are listed, last.
    public init(stored: [String]?, known: [String], defaults: [String]) {
        var seen = Set<String>()
        let knownSet = Set(known)
        let chosen = (stored ?? defaults).filter { knownSet.contains($0) && seen.insert($0).inserted }
        enabled = chosen
        all = chosen + known.filter { !seen.contains($0) }
    }

    public func isEnabled(_ id: String) -> Bool { enabled.contains(id) }

    public mutating func set(_ id: String, enabled on: Bool) {
        guard all.contains(id), on != isEnabled(id) else { return }
        rebuild(enabled: on ? enabled + [id] : enabled.filter { $0 != id })
    }

    /// Moves an action by `offset` places in the full list. Past either end it stops there.
    public mutating func move(_ id: String, by offset: Int) {
        guard let from = all.firstIndex(of: id) else { return }
        let to = min(max(0, from + offset), all.count - 1)
        guard to != from else { return }
        all.remove(at: from)
        all.insert(id, at: to)
        rebuild(enabled: enabled)
    }

    private mutating func rebuild(enabled wanted: [String]) {
        let on = Set(wanted)
        enabled = all.filter { on.contains($0) }
    }
}

/// Bounds of the panel's width, in points
public enum SidePanelWidth {
    public static let minimum: CGFloat = 200
    public static let maximum: CGFloat = 480
    public static let standard: CGFloat = 280

    public static func clamped(_ width: CGFloat) -> CGFloat {
        guard width.isFinite else { return standard }
        return min(maximum, max(minimum, width))
    }
}
