import AppKit
@testable import HSpaceApp
import Testing

@Suite struct TestRunDefaultsIsolation {
    private let name = "com.hoax017.hspace.tests.\(UUID().uuidString)"

    private func sandbox() throws -> DefaultsSandbox {
        DefaultsSandbox(defaults: try #require(UserDefaults(suiteName: name)), domain: name)
    }

    private func cleanUp(_ sandbox: DefaultsSandbox) {
        sandbox.defaults.removePersistentDomain(forName: name)
    }

    @Test func theKeyIsOnlyRenamedInATestRun() {
        #expect(TestIsolation.defaultsKey("seedsMergedV2", isolated: true) == "seedsMergedV2.uitest")
        #expect(TestIsolation.defaultsKey("seedsMergedV2", isolated: false) == "seedsMergedV2")
    }

    @Test func aRunLeavesTheUsersPreferencesAsTheyWere() throws {
        let sandbox = try sandbox()
        defer { cleanUp(sandbox) }
        sandbox.defaults.set("user", forKey: "changed")
        sandbox.defaults.set(true, forKey: "removed")
        sandbox.begin()
        sandbox.defaults.set("test", forKey: "changed")
        sandbox.defaults.set("test", forKey: "added")
        sandbox.defaults.removeObject(forKey: "removed")
        sandbox.end()
        #expect(sandbox.defaults.string(forKey: "changed") == "user")
        #expect(sandbox.defaults.object(forKey: "added") == nil)
        #expect(sandbox.defaults.bool(forKey: "removed"))
        #expect(sandbox.defaults.persistentDomain(forName: name)?.count == 2)
    }

    @Test func theTestRunsOwnKeysSurviveForTheNextLaunch() throws {
        let sandbox = try sandbox()
        defer { cleanUp(sandbox) }
        sandbox.begin()
        sandbox.defaults.set("900x520", forKey: "windowFrame.uitest")
        sandbox.end()
        #expect(sandbox.defaults.string(forKey: "windowFrame.uitest") == "900x520")
    }

    @Test func aRunThatDiedIsRepairedByTheNextOne() throws {
        let sandbox = try sandbox()
        defer { cleanUp(sandbox) }
        sandbox.defaults.set("user", forKey: "pref")
        sandbox.begin()
        sandbox.defaults.set("polluted", forKey: "pref")
        // No end(): the process died here
        sandbox.begin()
        #expect(sandbox.defaults.string(forKey: "pref") == "user")
        sandbox.defaults.set("polluted again", forKey: "pref")
        sandbox.end()
        #expect(sandbox.defaults.string(forKey: "pref") == "user")
    }

    @Test func endWithoutBeginChangesNothing() throws {
        let sandbox = try sandbox()
        defer { cleanUp(sandbox) }
        sandbox.defaults.set("user", forKey: "pref")
        sandbox.end()
        #expect(sandbox.defaults.string(forKey: "pref") == "user")
    }
}

@Suite struct TestRunClipboardIsolation {
    @Test func theClipboardComesBackWithEveryRepresentation() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.hoax017.hspace.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let custom = NSPasteboard.PasteboardType("com.hoax017.hspace.tests.custom")
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("user text", forType: .string)
        item.setData(Data([1, 2, 3]), forType: custom)
        pasteboard.writeObjects([item])

        let snapshot = PasteboardSnapshot(of: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("test text", forType: .string)
        snapshot.restore(to: pasteboard)

        #expect(pasteboard.string(forType: .string) == "user text")
        #expect(pasteboard.data(forType: custom) == Data([1, 2, 3]))
    }
}
