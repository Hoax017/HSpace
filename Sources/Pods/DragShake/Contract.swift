import Foundation

// DragShake pod's sole public contract surface (Axiom 3): telling a deliberate shake of the pointer from ordinary dragging.
// Pure: it sees positions and times only, so the rule is the same for every source of events.

public struct ShakeDetector: Sendable {
    /// Pointer travel each way that counts, in points. Less is a hand's tremor.
    public static let minTravel = 48.0
    /// Changes of direction that make a shake
    public static let turnsNeeded = 3
    /// All of them within this many seconds. Slower is someone looking for a place to drop.
    public static let timeWindow = 0.6

    private var heading = 0.0
    /// Farthest point reached in the current heading
    private var extreme: Double?
    private var turns: [TimeInterval] = []
    private var fired = false

    public init() {}

    /// Takes the next pointer position. True once when a shake completes, and not again until `reset`.
    public mutating func feed(x: Double, time: TimeInterval) -> Bool {
        guard !fired else { return false }
        guard let last = extreme else {
            extreme = x
            return false
        }
        let moved = x - last
        if heading == 0 {
            if abs(moved) >= Self.minTravel { heading = moved > 0 ? 1 : -1; extreme = x }
            return false
        }
        if moved * heading > 0 {
            extreme = x
        } else if abs(moved) >= Self.minTravel {
            heading = -heading
            extreme = x
            turns = turns.filter { time - $0 <= Self.timeWindow } + [time]
            if turns.count >= Self.turnsNeeded {
                fired = true
                return true
            }
        }
        return false
    }

    /// A new drag begins
    public mutating func reset() {
        self = ShakeDetector()
    }
}
