import KeyboardSelection
import Testing

@Suite struct KeyboardSelectionTests {
    private let all: (Int) -> Bool = { _ in true }

    @Test func theFirstPressStartsAtTheTop() {
        #expect(KeyboardSelection.step(cursor: nil, lastSelected: nil, count: 3, isItem: all) == SelectionStep(toggle: 0, next: 1))
    }

    @Test func itStartsFromTheSelectionWhenNoCursorShows() {
        #expect(KeyboardSelection.step(cursor: nil, lastSelected: 1, count: 3, isItem: all) == SelectionStep(toggle: 1, next: 2))
    }

    @Test func theCursorWinsOverTheSelection() {
        #expect(KeyboardSelection.step(cursor: 2, lastSelected: 0, count: 4, isItem: all) == SelectionStep(toggle: 2, next: 3))
    }

    @Test func atTheEndItStays() {
        #expect(KeyboardSelection.step(cursor: 2, lastSelected: nil, count: 3, isItem: all) == SelectionStep(toggle: 2, next: 2))
    }

    @Test func headersAreSkipped() {
        let items: (Int) -> Bool = { $0 != 0 && $0 != 2 }
        #expect(KeyboardSelection.step(cursor: nil, lastSelected: nil, count: 4, isItem: items) == SelectionStep(toggle: 1, next: 3))
    }

    @Test func aHeaderAtTheEndFallsBackToTheLastItem() {
        #expect(KeyboardSelection.step(cursor: 2, lastSelected: nil, count: 3, isItem: { $0 == 0 }) == SelectionStep(toggle: 0, next: 0))
    }

    @Test func aCursorPastTheEndIsPulledBack() {
        #expect(KeyboardSelection.step(cursor: 9, lastSelected: nil, count: 2, isItem: all) == SelectionStep(toggle: 1, next: 1))
    }

    @Test func nothingToSelectGivesNothing() {
        #expect(KeyboardSelection.step(cursor: nil, lastSelected: nil, count: 0, isItem: all) == nil)
        #expect(KeyboardSelection.step(cursor: nil, lastSelected: nil, count: 2, isItem: { _ in false }) == nil)
    }

    @Test func movingStopsAtTheEndsAndSkipsHeaders() {
        #expect(KeyboardSelection.move(cursor: 1, by: 1, count: 3, isItem: all) == 2)
        #expect(KeyboardSelection.move(cursor: 2, by: 5, count: 3, isItem: all) == 2)
        #expect(KeyboardSelection.move(cursor: 1, by: -5, count: 3, isItem: all) == 0)
        #expect(KeyboardSelection.move(cursor: 1, by: 1, count: 4, isItem: { $0 != 2 }) == 3)
        #expect(KeyboardSelection.move(cursor: 1, by: -1, count: 3, isItem: { $0 != 0 }) == 1)
    }
}

@Suite struct SpaceRoleTests {
    @Test func theSettingOffAlwaysPreviews() {
        #expect(SpaceRole.role(settingOn: false, isSpaceKeyPress: true, hasModifiers: false, previewShowing: false) == .quickLook)
    }

    @Test func plainSpaceSelects() {
        #expect(SpaceRole.role(settingOn: true, isSpaceKeyPress: true, hasModifiers: false, previewShowing: false) == .toggleSelection)
    }

    @Test func shiftSpaceStillPreviews() {
        #expect(SpaceRole.role(settingOn: true, isSpaceKeyPress: true, hasModifiers: true, previewShowing: false) == .quickLook)
    }

    @Test func aMenuClickStillPreviews() {
        #expect(SpaceRole.role(settingOn: true, isSpaceKeyPress: false, hasModifiers: false, previewShowing: false) == .quickLook)
    }

    @Test func anOpenPreviewCanBeClosed() {
        #expect(SpaceRole.role(settingOn: true, isSpaceKeyPress: true, hasModifiers: false, previewShowing: true) == .quickLook)
    }
}
