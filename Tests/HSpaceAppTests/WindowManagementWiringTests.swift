import AppKit
import HSpaceTestSupport
import PreferencesTransfer
import Testing
import WindowRules
@testable import HSpaceApp

@MainActor @Suite struct WindowManagementWiringTests {
    private func suite() throws -> (UserDefaults, () -> Void) {
        let name = "hspace-windows-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }

    /// A minimal app bundle; nil id leaves the identifier out
    private func fakeApp(_ name: String, id: String?, in dir: URL) throws -> URL {
        let app = dir.appendingPathComponent("\(name).app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleName": name, "CFBundlePackageType": "APPL"]
        if let id { info["CFBundleIdentifier"] = id }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try FaultFixture.write(data, to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    @Test func optionsSurviveTheirStore() throws {
        let (defaults, drop) = try suite()
        defer { drop() }
        #expect(WindowSettings.options(defaults) == WindowOptions())
        let chosen = WindowOptions(launch: .home, newWindow: .current, lastTab: .keepWindow, quitAfterLastWindow: true)
        WindowSettings.save(chosen, defaults)
        #expect(WindowSettings.options(defaults) == chosen)
        defaults.set("sideways", forKey: WindowSettings.launchKey)
        #expect(WindowSettings.options(defaults).launch == .restore)
    }

    @Test func theSettingsPageStoresWhatItShows() throws {
        let (defaults, drop) = try suite()
        defer { drop() }
        let page = WindowsSettingsPage(defaults: defaults)
        _ = page.makeView()
        #expect(page.shownOptions == WindowOptions())
        page.select(launch: .home, lastTab: .keepWindow, quit: true)
        #expect(WindowSettings.options(defaults) == WindowOptions(launch: .home, lastTab: .keepWindow, quitAfterLastWindow: true))
        let reopened = WindowsSettingsPage(defaults: defaults)
        _ = reopened.makeView()
        #expect(reopened.shownOptions == WindowSettings.options(defaults))
    }

    @Test func appsAreExcludedByBundleIDAndRemoved() throws {
        let (defaults, drop) = try suite()
        defer { drop() }
        let dir = try FaultFixture.tempDir("hspace-windows")
        defer { FaultFixture.remove(dir) }
        let page = WindowsSettingsPage(defaults: defaults)
        var reported: [AppExclusions] = []
        page.onExclusionsChanged = { reported.append($0) }
        _ = page.makeView()
        #expect(page.shownAppIDs.isEmpty)

        #expect(page.exclude(appAt: try fakeApp("Editor", id: "test.hspace.Editor", in: dir)))
        #expect(!page.exclude(appAt: try fakeApp("Nameless", id: nil, in: dir)))
        #expect(WindowSettings.exclusions(defaults).bundleIDs == ["test.hspace.Editor"])
        #expect(page.shownAppIDs == ["test.hspace.Editor"])
        #expect(reported.count == 1)

        page.include("TEST.HSPACE.EDITOR")
        #expect(defaults.object(forKey: WindowSettings.exclusionsKey) == nil)
        #expect(page.shownAppIDs.isEmpty)
        #expect(reported.last?.isEmpty == true)
    }

    @Test func theMonitorListensOnlyWhileAppsAreExcluded() async throws {
        let center = NotificationCenter()
        var front: String? = "com.example.Editor"
        let monitor = AppExclusionMonitor(center: center, own: "dev.hspace.test", frontmost: { front })
        defer { monitor.stop() }
        var changes: [Bool] = []
        monitor.onChange = { changes.append($0) }

        monitor.update(AppExclusions())
        #expect(!monitor.isListening)
        #expect(!monitor.isSilenced)

        monitor.update(AppExclusions(["com.example.Editor"]))
        #expect(monitor.isListening)
        #expect(monitor.isSilenced, "the excluded app was already in front")

        // An app switch with no app named counts as one not on the list
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        await eventually("released") { !monitor.isSilenced }

        monitor.frontmostChanged("dev.hspace.test")
        #expect(!monitor.isSilenced)
        monitor.frontmostChanged("com.example.editor")
        #expect(monitor.isSilenced)

        front = nil
        monitor.update(AppExclusions())
        #expect(!monitor.isListening)
        #expect(!monitor.isSilenced)
        #expect(changes == [true, false, true, false])
    }

    @Test func aSuspendedHotkeyIsReleased() {
        defer { GlobalHotkey.setSuspended(false) }
        GlobalHotkey.setSuspended(true)
        #expect(GlobalHotkey.isSuspended)
        #expect(GlobalHotkey.apply(), "nothing is registered while suspended, which is not a failure")
        GlobalHotkey.setSuspended(false)
        #expect(!GlobalHotkey.isSuspended)
    }

    @Test func windowOptionsAndExclusionsTravelInPreferences() {
        let schema = PreferencesCatalog.schema()
        #expect(schema.validated(WindowSettings.launchKey, .text("home")) != nil)
        #expect(schema.validated(WindowSettings.lastTabKey, .text("keepWindow")) != nil)
        #expect(schema.validated(WindowSettings.newWindowKey, .text("current")) != nil)
        #expect(schema.validated(WindowSettings.quitKey, .bool(true)) != nil)
        #expect(schema.validated(WindowSettings.exclusionsKey, .list(["com.apple.dt.Xcode"])) != nil)
        #expect(schema.validated(WindowSettings.exclusionsKey, .list(["no spaces"])) == nil)
    }
}
