import Testing
import Foundation
import SessionStore

/// Black-box acceptance: real temp directory (no fakes or mocks)
@Suite struct SessionStoreTests {
    func makeStore() throws -> (SessionStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hspace-ss-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (SessionStore(directory: dir), dir)
    }

    static func sample() -> SessionSnapshot {
        SessionSnapshot(windows: [
            SessionWorkspaces(workspaces: [
                SessionWindow(layoutRaw: 5,
                              panes: [
                                SessionPane(tab: SessionTab(path: "/usr", sortKey: "size",
                                                            sortAscending: false)),
                                SessionPane(tab: SessionTab(path: "/", includeHidden: true)),
                              ],
                              activePaneIndex: 1),
                SessionWindow(layoutRaw: 1,
                              panes: [SessionPane(tab: SessionTab(path: "/etc"))],
                              activePaneIndex: 0),
            ], activeWorkspace: 0),
        ])
    }

    @Test func roundTripThroughDisk() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let snap = Self.sample()
        await store.save(snap)
        await store.flush()  // skip the debounce and persist immediately
        // A new instance reloads from disk (cross-launch restore acceptance)
        let store2 = SessionStore(directory: dir)
        let loaded = await store2.load()
        #expect(loaded == snap)
    }

    @Test func missingFileReturnsNil() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let loaded = await store.load()
        #expect(loaded == nil)
    }

    @Test func corruptFileReturnsNil() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("not json{{".utf8).write(to: dir.appendingPathComponent("session.json"))
        let loaded = await store.load()
        #expect(loaded == nil)
    }

    @Test func debounceCoalescesWrites() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Consecutive saves keep only the last one (debounce coalescing)
        var snap = Self.sample()
        await store.save(snap)
        snap.windows[0].activeWorkspace = 1
        await store.save(snap)
        await store.flush()
        let loaded = await SessionStore(directory: dir).load()
        #expect(loaded?.windows[0].activeWorkspace == 1)
    }

    /// One-time migration of the old format (each windows item directly a SessionWindow): wrapped into one window's workspace array
    @Test func legacyFormatMigratesToWorkspaces() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Hand-written old-structure JSON (M13: windows=[SessionWindow], one copy each)
        let legacyJSON = """
        {"windows":[
          {"layoutRaw":1,"activePaneIndex":0,"panes":[{"activeTabIndex":0,"tabs":[{"path":"/tmp","sortKey":"name","sortAscending":true,"includeHidden":false}]}]},
          {"layoutRaw":2,"activePaneIndex":0,"panes":[{"activeTabIndex":0,"tabs":[{"path":"/usr","sortKey":"name","sortAscending":true,"includeHidden":false}]}]}
        ]}
        """
        try Data(legacyJSON.utf8).write(to: dir.appendingPathComponent("session.json"))
        let loaded = await store.load()
        // Two old windows → two workspaces of one window
        #expect(loaded?.windows.count == 1)
        #expect(loaded?.windows[0].workspaces.count == 2)
        #expect(loaded?.windows[0].activeWorkspace == 0)
        #expect(loaded?.windows[0].workspaces[1].layoutRaw == 2)
    }

    /// One-time migration for retiring per-pane tabs (M13): in old archives each pane has a `tabs` array + `activeTabIndex`,
    /// the new structure has one `tab`. It must keep **the one active at the time**, not the first: in real user sessions the active tab
    /// is usually not 0 (external opens kept piling on), and picking wrong swaps the directory they were viewing for one from long ago.
    @Test func legacyPaneTabsKeepActiveTabOnly() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacyJSON = """
        {"windows":[{"activeWorkspace":0,"workspaces":[
          {"layoutRaw":2,"activePaneIndex":0,"panes":[
            {"activeTabIndex":2,"tabs":[
              {"path":"/tmp","sortKey":"name","sortAscending":true,"includeHidden":false},
              {"path":"/usr","sortKey":"name","sortAscending":true,"includeHidden":false},
              {"path":"/etc","sortKey":"size","sortAscending":false,"includeHidden":true,"viewMode":0}]},
            {"activeTabIndex":0,"tabs":[
              {"path":"/var","sortKey":"name","sortAscending":true,"includeHidden":false}]}
          ]}
        ]}]}
        """
        try Data(legacyJSON.utf8).write(to: dir.appendingPathComponent("session.json"))
        let loaded = await store.load()
        let panes = try #require(loaded?.windows.first?.workspaces.first?.panes)
        #expect(panes.count == 2)
        // The one at index 2 (not /tmp), bringing its sort/hidden/view mode along
        #expect(panes[0].tab.path == "/etc")
        #expect(panes[0].tab.sortKey == "size")
        #expect(panes[0].tab.sortAscending == false)
        #expect(panes[0].tab.includeHidden == true)
        #expect(panes[0].tab.viewMode == 0)
        #expect(panes[1].tab.path == "/var")
    }

    /// An out-of-range activeTabIndex must not fail decoding of the whole session (that would lose all the user's windows at once)
    @Test func legacyPaneTabsOutOfRangeIndexFallsBackToFirst() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacyJSON = """
        {"windows":[{"activeWorkspace":0,"workspaces":[
          {"layoutRaw":1,"activePaneIndex":0,"panes":[
            {"activeTabIndex":7,"tabs":[
              {"path":"/tmp","sortKey":"name","sortAscending":true,"includeHidden":false}]}
          ]}
        ]}]}
        """
        try Data(legacyJSON.utf8).write(to: dir.appendingPathComponent("session.json"))
        let loaded = await store.load()
        #expect(loaded?.windows.first?.workspaces.first?.panes.first?.tab.path == "/tmp")
    }

    /// Migration happens only on that one read: saving writes the new structure, and old keys no longer appear on disk
    @Test func migratedSessionWritesNewShapeOnly() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.json")
        let legacyJSON = """
        {"windows":[{"activeWorkspace":0,"workspaces":[
          {"layoutRaw":1,"activePaneIndex":0,"panes":[
            {"activeTabIndex":1,"tabs":[
              {"path":"/tmp","sortKey":"name","sortAscending":true,"includeHidden":false},
              {"path":"/usr","sortKey":"name","sortAscending":true,"includeHidden":false}]}
          ]}
        ]}]}
        """
        try Data(legacyJSON.utf8).write(to: file)
        let loaded = try #require(await store.load())
        await store.save(loaded)
        await store.flush()
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("\"tab\""))
        #expect(!text.contains("\"tabs\""))
        #expect(!text.contains("activeTabIndex"))
        #expect(text.contains("/usr"))       // what stays is the one active at the time
        #expect(!text.contains("/tmp"))
    }
}
