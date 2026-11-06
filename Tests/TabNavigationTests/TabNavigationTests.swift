import TabNavigation
import Testing

@Suite struct TabRecencyTests {
    @Test func theLastUsedTabComesFirst() {
        var recency = TabRecency(active: 0)
        recency.touch(2)
        recency.touch(1)
        recency.touch(2)
        #expect(recency.order == [2, 1, 0])
        #expect(recency.mostRecent == 2)
    }

    @Test func closingATabShiftsTheOnesAfterIt() {
        var recency = TabRecency(active: 0)
        recency.touch(3)
        recency.touch(1)
        recency.remove(at: 1)
        #expect(recency.order == [2, 0])
    }

    @Test func droppingTheOldestTabsForgetsThem() {
        var recency = TabRecency(active: 0)
        recency.touch(1)
        recency.touch(4)
        recency.removeFirst(2)
        #expect(recency.order == [2])
    }

    @Test func tabsNeverUsedFollowInTabOrder() {
        var recency = TabRecency(active: 3)
        recency.touch(1)
        #expect(recency.all(count: 5) == [1, 3, 0, 2, 4])
    }

    @Test func aStaleEntryIsLeftOut() {
        let recency = TabRecency(active: 7)
        #expect(recency.all(count: 2) == [0, 1])
    }

    @Test func removingTheOnlyTabLeavesNothingToReturnTo() {
        var recency = TabRecency(active: 0)
        recency.remove(at: 0)
        #expect(recency.mostRecent == nil)
    }
}

@Suite struct TabSwitcherSessionTests {
    @Test func oneTabHasNothingToSwitchTo() {
        #expect(TabSwitcherSession(tabs: [0]) == nil)
        #expect(TabSwitcherSession(tabs: []) == nil)
    }

    @Test func itStartsOnThePreviousTab() throws {
        let session = try #require(TabSwitcherSession(tabs: [4, 2, 0]))
        #expect(session.selected == 2)
    }

    @Test func startingBackwardGoesToTheOldestTab() throws {
        let session = try #require(TabSwitcherSession(tabs: [4, 2, 0], backward: true))
        #expect(session.selected == 0)
    }

    @Test func steppingWrapsAtBothEnds() throws {
        var session = try #require(TabSwitcherSession(tabs: [4, 2, 0]))
        session.step(backward: false)
        #expect(session.selected == 0)
        session.step(backward: false)
        #expect(session.selected == 4)
        session.step(backward: true)
        #expect(session.selected == 0)
    }

    @Test func aRowOutOfRangeChangesNothing() throws {
        var session = try #require(TabSwitcherSession(tabs: [4, 2]))
        session.select(position: 0)
        #expect(session.selected == 4)
        session.select(position: 9)
        session.select(position: -1)
        #expect(session.selected == 4)
    }
}
