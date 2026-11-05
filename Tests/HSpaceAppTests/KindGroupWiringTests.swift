import Foundation
import FileMetadata
import HSpaceContracts
import Testing
@testable import HSpaceApp

private func item(_ name: String, type: String?) -> FileItem {
    FileItem(url: URL(fileURLWithPath: "/x/\(name)"), name: name, isDirectory: false, isPackage: false,
             isSymlink: false, isHidden: false, size: nil, modified: nil, created: nil, contentTypeID: type)
}

@Suite struct KindGroupMatchesTests {
    @Test func dottedEntriesAreTypesAndOthersExtensions() {
        var group = KindGroup(name: "G")
        KindGroupMatches.apply("public.image, .heic  raw,", to: &group)
        #expect(group.typeIDs == ["public.image"])
        #expect(group.extensions == ["heic", "raw"])
        #expect(KindGroupMatches.text(for: group) == "public.image, heic, raw")
    }

    @Test func emptyTextClearsBoth() {
        var group = KindGroup(name: "G", extensions: ["a"], typeIDs: ["b.c"])
        KindGroupMatches.apply(" ", to: &group)
        #expect(group.extensions.isEmpty && group.typeIDs.isEmpty)
    }
}

@MainActor @Suite struct KindBucketTests {
    private let groups = [KindGroup(name: "Images", typeIDs: ["public.image"]),
                          KindGroup(name: "Text", typeIDs: ["public.plain-text"]),
                          KindGroup(name: "Empty", extensions: ["none"])]
    private let items = [item("a.txt", type: "public.plain-text"), item("b.png", type: "public.png"),
                         item("c", type: nil), item("d.png", type: "public.png")]

    @Test func groupsFollowTheManagerOrderAndOtherComesLast() {
        let buckets = FileGrouping.kindBuckets(items, groups: groups, ascending: true)
        #expect(buckets.map(\.title) == ["Images", "Text", "group.otherKinds"])
        #expect(buckets.map(\.indices) == [[1, 3], [0], [2]])
    }

    @Test func descendingReversesGroupsButKeepsOtherLast() {
        let buckets = FileGrouping.kindBuckets(items, groups: groups, ascending: false)
        #expect(buckets.map(\.title) == ["Text", "Images", "group.otherKinds"])
    }

    @Test func noGroupsMeansOneOtherGroup() {
        let buckets = FileGrouping.kindBuckets(items, groups: [], ascending: true)
        #expect(buckets.count == 1)
        #expect(buckets[0].indices == [0, 1, 2, 3])
    }

    @Test func kindSortGroupsOnlyWhenGroupingIsOn() throws {
        let model = DirectoryViewModel(directory: URL(fileURLWithPath: "/"))
        defer { model.stopWatching() }
        let saved = Preferences.listGrouping
        defer { Preferences.listGrouping = saved }
        model.sort = SortSpec(key: .kind)
        Preferences.listGrouping = true
        #expect(FileGrouping.active(model))
        Preferences.listGrouping = false
        #expect(!FileGrouping.active(model))
        Preferences.listGrouping = true
        model.setTagSort(ascending: true)
        #expect(!FileGrouping.active(model))
    }
}
