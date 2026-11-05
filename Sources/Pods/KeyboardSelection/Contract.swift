import Foundation

// KeyboardSelection pod's sole public contract surface (Axiom 3): picking items one by one from the keyboard.
// Space toggles the item at a cursor and moves on, so a scattered set can be built without the mouse.
// Positions are plain indexes: the views own what they mean.

/// One press of Space
public struct SelectionStep: Sendable, Equatable {
    /// The position whose selection flips
    public let toggle: Int
    /// Where the cursor goes next. At the last item it stays.
    public let next: Int

    public init(toggle: Int, next: Int) {
        self.toggle = toggle
        self.next = next
    }
}

public enum KeyboardSelection {
    /// - Parameters:
    ///   - cursor: where the cursor is, if it is showing
    ///   - lastSelected: where the selection last grew, the start when no cursor shows
    ///   - isItem: false for positions that hold no item, such as group headers
    /// nil when there is no item at all.
    public static func step(cursor: Int?, lastSelected: Int?, count: Int, isItem: (Int) -> Bool) -> SelectionStep? {
        guard let start = firstItem(from: cursor ?? lastSelected ?? 0, count: count, by: 1, isItem: isItem)
            ?? firstItem(from: count - 1, count: count, by: -1, isItem: isItem) else { return nil }
        let after = firstItem(from: start + 1, count: count, by: 1, isItem: isItem) ?? start
        return SelectionStep(toggle: start, next: after)
    }

    /// The cursor after moving by `offset`. At either end, it stops on the last item it can reach.
    public static func move(cursor: Int, by offset: Int, count: Int, isItem: (Int) -> Bool) -> Int {
        guard offset != 0 else { return cursor }
        let wanted = min(count - 1, max(0, cursor + offset))
        return firstItem(from: wanted, count: count, by: offset > 0 ? 1 : -1, isItem: isItem)
            ?? firstItem(from: wanted, count: count, by: offset > 0 ? -1 : 1, isItem: isItem)
            ?? cursor
    }

    private static func firstItem(from start: Int, count: Int, by delta: Int, isItem: (Int) -> Bool) -> Int? {
        var index = start
        while index >= 0, index < count {
            if isItem(index) { return index }
            index += delta
        }
        return nil
    }
}

/// What Space means now
public enum SpaceRole: Sendable, Equatable {
    case quickLook, toggleSelection

    /// With the setting on, plain Space selects and Shift-Space previews. Pressed while the preview shows, Space closes it,
    /// whatever the setting. Anything but a key press (a menu click, a panel button) means the preview.
    public static func role(settingOn: Bool, isSpaceKeyPress: Bool, hasModifiers: Bool, previewShowing: Bool) -> SpaceRole {
        settingOn && isSpaceKeyPress && !hasModifiers && !previewShowing ? .toggleSelection : .quickLook
    }
}
