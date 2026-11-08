import ContextMenuLayout
import Foundation
import Testing

@Suite struct ContextMenuSettingsTests {
    private let sections = [["open", "openWith"], ["copy", "cut", "paste"], ["trash"]]

    @Test func theDefaultShowsEverythingInPlace() {
        let settings = ContextMenuSettings()
        #expect(settings.isDefault)
        #expect(settings.arranged(sections) == sections)
    }

    @Test func hiddenEntriesLeaveTheMenu() {
        var settings = ContextMenuSettings()
        settings.setHidden("cut", true)
        #expect(settings.arranged(sections) == [["open", "openWith"], ["copy", "paste"], ["trash"]])
        settings.setHidden("cut", false)
        #expect(settings.isDefault)
    }

    @Test func aSectionWithNothingLeftIsDropped() {
        let settings = ContextMenuSettings(hidden: ["trash", "open", "openWith"])
        #expect(settings.arranged(sections) == [["copy", "cut", "paste"]])
    }

    @Test func hidingEverythingLeavesAnEmptyMenu() {
        let settings = ContextMenuSettings(hidden: sections.flatMap { $0 })
        #expect(settings.arranged(sections).isEmpty)
    }

    @Test func movingStaysInsideTheSection() {
        var settings = ContextMenuSettings()
        settings.move("paste", by: -1, in: sections)
        #expect(settings.ordered(sections) == [["open", "openWith"], ["copy", "paste", "cut"], ["trash"]])
        settings.move("paste", by: -5, in: sections)
        #expect(settings.ordered(sections)[1] == ["paste", "copy", "cut"])
        settings.move("open", by: 9, in: sections)
        #expect(settings.ordered(sections)[0] == ["openWith", "open"])
        #expect(settings.ordered(sections)[2] == ["trash"])
    }

    @Test func movingPastTheEdgeChangesNothing() {
        var settings = ContextMenuSettings()
        settings.move("open", by: -1, in: sections)
        settings.move("trash", by: 1, in: sections)
        #expect(settings.isDefault)
    }

    @Test func anUnknownIdChangesNothing() {
        var settings = ContextMenuSettings()
        settings.move("gone", by: 1, in: sections)
        #expect(settings.isDefault)
    }

    @Test func hiddenEntriesStillMoveAndKeepTheirPlace() {
        var settings = ContextMenuSettings(hidden: ["cut"])
        settings.move("cut", by: -1, in: sections)
        #expect(settings.ordered(sections)[1] == ["cut", "copy", "paste"])
        settings.setHidden("cut", false)
        #expect(settings.arranged(sections)[1] == ["cut", "copy", "paste"])
    }

    @Test func aNewEntryGoesAfterTheOrderedOnes() {
        let settings = ContextMenuSettings(order: ["paste", "copy", "cut"])
        let later = [["copy", "duplicate", "cut", "paste"]]
        #expect(settings.arranged(later) == [["paste", "copy", "cut", "duplicate"]])
    }

    @Test func anEntryTheAppLostIsRememberedForWhenItReturns() {
        var settings = ContextMenuSettings(order: ["paste", "gone", "copy"])
        settings.move("cut", by: -1, in: [["copy", "cut", "paste"]])
        #expect(settings.order.contains("gone"))
        #expect(settings.arranged([["copy", "cut", "paste"]]) == [["paste", "cut", "copy"]])
    }

    @Test func storedRepeatsAreDropped() {
        let settings = ContextMenuSettings(hidden: ["b", "a", "b"], order: ["x", "y", "x"])
        #expect(settings.hidden == ["a", "b"])
        #expect(settings.order == ["x", "y"])
    }
}
