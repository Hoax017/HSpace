import Foundation
import Testing
import ViewStyles

@Suite struct IconLayoutTests {
    @Test func valuesOutOfRangeLandOnTheNearestAllowed() {
        let small = IconLayout(iconSize: 1, spacing: 7, label: .bottom)
        #expect(small.iconSize == 32)
        #expect(small.spacing == 8)
        let large = IconLayout(iconSize: 9000, spacing: 100, label: .right)
        #expect(large.iconSize == 256)
        #expect(large.spacing == 24)
    }

    @Test func aNameBelowAddsHeightAndANameBesideAddsWidth() {
        let below = IconLayout(iconSize: 64, spacing: 8, label: .bottom).itemSize
        #expect(below.width == 96)
        #expect(below.height == 108)
        let beside = IconLayout(iconSize: 64, spacing: 8, label: .right).itemSize
        #expect(beside.width == 64 + 12 + IconLayout.sideLabelWidth)
        #expect(beside.height == 72)
    }

    @Test func aSmallIconStillLeavesRoomForTwoLinesBesideIt() {
        #expect(IconLayout(iconSize: 32, spacing: 8, label: .right).itemSize.height == 44)
    }

    @Test func thumbnailsComeInTwoSizes() {
        #expect(IconLayout(iconSize: 48, spacing: 8, label: .bottom).thumbnailSize == 128)
        #expect(IconLayout(iconSize: 128, spacing: 8, label: .bottom).thumbnailSize == 128)
        #expect(IconLayout(iconSize: 129, spacing: 8, label: .bottom).thumbnailSize == 256)
    }

    @Test func aStyleSavedBeforeIconOptionsStillLoads() throws {
        let old = Data(#"{"viewMode":0,"sortKey":"name"}"#.utf8)
        let style = try JSONDecoder().decode(ViewStyle.self, from: old)
        #expect(style.viewMode == 0)
        #expect(style.iconLayout == nil)
    }

    @Test func anEditedFileCannotBreakTheGrid() throws {
        let edited = Data(#"{"iconSize":-5,"spacing":3,"label":"bottom"}"#.utf8)
        let layout = try JSONDecoder().decode(IconLayout.self, from: edited)
        #expect(layout.iconSize == 32)
        #expect(layout.spacing == 4)
    }

    @Test func aLayoutTravelsWithItsStyle() throws {
        let style = ViewStyle(viewMode: 0, iconLayout: IconLayout(iconSize: 200, spacing: 16, label: .right))
        let back = try JSONDecoder().decode(ViewStyle.self, from: JSONEncoder().encode(style))
        #expect(back == style)
    }
}
