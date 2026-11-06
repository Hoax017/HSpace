import DragShake
import Foundation
import Testing

@Suite struct ShakeDetectorTests {
    /// Feeds positions a fixed time apart; returns how many fed positions reported a shake
    private func run(_ detector: inout ShakeDetector, _ positions: [Double], step: TimeInterval = 0.05, from start: TimeInterval = 0) -> Int {
        var fired = 0
        for (i, x) in positions.enumerated() where detector.feed(x: x, time: start + Double(i) * step) { fired += 1 }
        return fired
    }

    @Test func threeQuickTurnsAreAShake() {
        var detector = ShakeDetector()
        #expect(run(&detector, [0, 100, 0, 100, 0]) == 1)
    }

    @Test func aLongStraightDragIsNot() {
        var detector = ShakeDetector()
        #expect(run(&detector, stride(from: 0.0, to: 2000, by: 50).map { $0 }) == 0)
    }

    @Test func smallWobblesAreNot() {
        var detector = ShakeDetector()
        #expect(run(&detector, [0, 100, 70, 100, 70, 100, 70, 100]) == 0)
    }

    @Test func slowBackAndForthIsNot() {
        var detector = ShakeDetector()
        #expect(run(&detector, [0, 100, 0, 100, 0, 100, 0], step: 0.5) == 0)
    }

    @Test func twoTurnsAreNotEnough() {
        var detector = ShakeDetector()
        #expect(run(&detector, [0, 100, 0, 100]) == 0)
    }

    @Test func itFiresOncePerDrag() {
        var detector = ShakeDetector()
        #expect(run(&detector, [0, 100, 0, 100, 0, 100, 0, 100, 0, 100]) == 1)
    }

    @Test func aResetAllowsAnotherShake() {
        var detector = ShakeDetector()
        #expect(run(&detector, [0, 100, 0, 100, 0]) == 1)
        detector.reset()
        #expect(run(&detector, [0, 100, 0, 100, 0], from: 10) == 1)
    }

    @Test func aResetForgetsPartOfAShake() {
        var detector = ShakeDetector()
        #expect(run(&detector, [0, 100, 0]) == 0)
        detector.reset()
        #expect(run(&detector, [0, 100, 0], from: 0.2) == 0)
    }

    @Test func aPauseStartsTheCountAgain() {
        var detector = ShakeDetector()
        #expect(run(&detector, [0, 100, 0]) == 0)
        #expect(run(&detector, [100, 0], from: 5) == 0)
    }
}
