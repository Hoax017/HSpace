import Foundation
import TabDrag
import Testing

@Suite struct TabMoveTests {
    private let edges: [(min: Double, max: Double)] = [(0, 100), (100, 200), (200, 300)]

    @Test func theGapFollowsTheMiddleOfEachTab() {
        #expect(TabMove.gap(at: -5, edges: edges) == 0)
        #expect(TabMove.gap(at: 49, edges: edges) == 0)
        #expect(TabMove.gap(at: 51, edges: edges) == 1)
        #expect(TabMove.gap(at: 260, edges: edges) == 3)
        #expect(TabMove.gap(at: 900, edges: edges) == 3)
    }

    @Test func noTabsMeansTheOnlyGap() {
        #expect(TabMove.gap(at: 10, edges: []) == 0)
    }

    @Test func movingRightLandsBeforeTheGap() {
        #expect(TabMove.destination(from: 0, gap: 2, count: 3) == 1)
        #expect(TabMove.destination(from: 0, gap: 3, count: 3) == 2)
    }

    @Test func movingLeftLandsOnTheGap() {
        #expect(TabMove.destination(from: 2, gap: 0, count: 3) == 0)
    }

    @Test func aGapBesideTheTabChangesNothing() {
        #expect(TabMove.destination(from: 1, gap: 1, count: 3) == nil)
        #expect(TabMove.destination(from: 1, gap: 2, count: 3) == nil)
    }

    @Test func outOfRangeChangesNothing() {
        #expect(TabMove.destination(from: 5, gap: 0, count: 3) == nil)
        #expect(TabMove.destination(from: 0, gap: 4, count: 3) == nil)
        #expect(TabMove.destination(from: -1, gap: 0, count: 3) == nil)
        #expect(TabMove.destination(from: 0, gap: -1, count: 3) == nil)
    }

    @Test func positionsFollowAMoveLikeTheArrayDoes() {
        for (from, to) in [(0, 3), (3, 0), (1, 2), (2, 1)] {
            var tabs = [0, 1, 2, 3]
            tabs.insert(tabs.remove(at: from), at: to)
            for old in 0..<4 {
                #expect(tabs[TabMove.moved(old, from: from, to: to)] == old)
            }
        }
    }
}

@Suite struct TabDragEndTests {
    private func end(accepted: Bool = false, cancelled: Bool = false, inside: Bool = false, tabs: Int = 2) -> TabDragEnd {
        TabDragEnd(accepted: accepted, cancelled: cancelled, insideSourceWindow: inside, tabCount: tabs)
    }

    @Test func droppedClearOfTheWindowDetaches() {
        #expect(end().detaches)
    }

    @Test func aDropAnotherStripTookStays() {
        #expect(!end(accepted: true).detaches)
    }

    @Test func escapeNeverDetaches() {
        #expect(!end(cancelled: true).detaches)
    }

    @Test func aDropOnItsOwnWindowStays() {
        #expect(!end(inside: true).detaches)
    }

    @Test func theLastTabHasNothingToLeave() {
        #expect(!end(tabs: 1).detaches)
    }
}

@Suite struct TabDragPayloadTests {
    @Test func itRoundTrips() throws {
        let payload = TabDragPayload(windowNumber: 42, index: 3)
        #expect(TabDragPayload.decoded(try payload.encoded()) == payload)
    }

    @Test func foreignDataIsNotAPayload() {
        #expect(TabDragPayload.decoded(Data("nope".utf8)) == nil)
    }
}
