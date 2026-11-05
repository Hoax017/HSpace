import Foundation
import FileMetadata
import HSpaceContracts
import HSpaceTestSupport
import Testing

private func item(_ name: String, type: String? = nil, directory: Bool = false) -> FileItem {
    FileItem(url: URL(fileURLWithPath: "/x/\(name)"), name: name, isDirectory: directory, isPackage: false,
             isSymlink: false, isHidden: false, size: nil, modified: nil, created: nil, contentTypeID: type)
}

@Suite struct KindGroupTests {
    private let images = KindGroup(name: "Images", typeIDs: ["public.image"])
    private let raw = KindGroup(name: "Raw", extensions: ["CR2", "nef"])
    private let folders = KindGroup(name: "Folders", typeIDs: ["public.folder"])

    @Test func typesMatchWithSubtypes() {
        let groups = [images]
        #expect(KindGroups.assign([item("a.png", type: "public.png")], to: groups) == [0])
        #expect(KindGroups.assign([item("a.txt", type: "public.plain-text")], to: groups) == [nil])
    }

    @Test func extensionsIgnoreCase() {
        #expect(KindGroups.assign([item("a.cr2"), item("b.NEF")], to: [raw]) == [0, 0])
    }

    @Test func aFolderNamedLikeAFileMatchesAsAFolder() {
        let folder = item("holiday.cr2", type: "public.folder", directory: true)
        #expect(KindGroups.assign([folder], to: [raw, folders]) == [1])
    }

    @Test func theFirstMatchingGroupWinsWhicheverWayItMatches() {
        let jpeg = item("a.jpg", type: "public.jpeg")
        let photos = KindGroup(name: "Photos", extensions: ["jpg"])
        #expect(KindGroups.assign([jpeg], to: [images, photos]) == [0])
        #expect(KindGroups.assign([jpeg], to: [photos, images]) == [0])
    }

    @Test func aFileWithNoTypeStaysOutside() {
        #expect(KindGroups.assign([item("mystery")], to: [images, raw, folders]) == [nil])
    }

    @Test func anUnknownTypeIDMatchesOnlyItself() {
        let custom = KindGroup(name: "X", typeIDs: ["com.example.nothing"])
        #expect(KindGroups.assign([item("a", type: "com.example.nothing"), item("b.png", type: "public.png")],
                                  to: [custom]) == [0, nil])
    }

    @Test func defaultsCoverTheCommonKinds() {
        let groups = KindGroups.defaults { $0 }
        let cases: [(FileItem, String)] = [
            (item("a.png", type: "public.png"), "kindGroup.images"),
            (item("a.mp4", type: "public.mpeg-4"), "kindGroup.movies"),
            (item("a.mp3", type: "public.mp3"), "kindGroup.audio"),
            (item("a.pdf", type: "com.adobe.pdf"), "kindGroup.documents"),
            (item("a.zip", type: "public.zip-archive"), "kindGroup.archives"),
            (item("a.swift", type: "public.swift-source"), "kindGroup.code"),
            (item("a", type: "public.folder", directory: true), "kindGroup.folders"),
        ]
        for (file, expected) in cases {
            let index = KindGroups.assign([file], to: groups)[0]
            #expect(index.map { groups[$0].name } == expected, "\(file.name)")
        }
    }
}

@Suite struct KindGroupStoreTests {
    @Test func untouchedGroupsReadAsNil() async throws {
        let dir = try FaultFixture.tempDir("hspace-mstore")
        defer { FaultFixture.remove(dir) }
        #expect(await MetadataStore(directory: dir).kindGroups() == nil)
    }

    @Test func savedGroupsSurviveARestartBesideTheRules() async throws {
        let dir = try FaultFixture.tempDir("hspace-mstore")
        defer { FaultFixture.remove(dir) }
        let group = KindGroup(name: "Mine", extensions: ["x"])
        let rule = ColorRule(color: .red, condition: .isFolder)
        let store = MetadataStore(directory: dir)
        try await store.setColorRules([rule])
        try await store.setKindGroups([group])

        let fresh = MetadataStore(directory: dir)
        #expect(await fresh.kindGroups() == [group])
        #expect(await fresh.colorRules() == [rule])
    }

    @Test func anEmptyListIsKept() async throws {
        let dir = try FaultFixture.tempDir("hspace-mstore")
        defer { FaultFixture.remove(dir) }
        try await MetadataStore(directory: dir).setKindGroups([])
        #expect(await MetadataStore(directory: dir).kindGroups() == [])
    }

    @Test func aFileFromBeforeKindGroupsStillLoads() async throws {
        let dir = try FaultFixture.tempDir("hspace-mstore")
        defer { FaultFixture.remove(dir) }
        try FaultFixture.write(Data(#"{"colorRules":[]}"#.utf8), to: dir.appendingPathComponent("file-metadata.json"))
        let store = MetadataStore(directory: dir)
        #expect(await store.kindGroups() == nil)
        #expect(await store.takeProblem() == nil)
    }

    @Test func aFailedSaveChangesNothing() async throws {
        let dir = try FaultFixture.tempDir("hspace-mstore")
        defer { FaultFixture.remove(dir) }
        let store = MetadataStore(directory: dir)
        try await store.setKindGroups([KindGroup(name: "A")])
        try await FaultFixture.withReadOnly(dir) {
            await #expect(throws: MetadataError.self) { try await store.setKindGroups([]) }
        }
        #expect(await store.kindGroups()?.count == 1)
    }
}
