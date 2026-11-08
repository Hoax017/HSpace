import Foundation
import HSpaceTestSupport
import PreferencesTransfer
import Testing
@testable import HSpaceApp

@MainActor @Suite struct PreferencesTransferWiringTests {
    private func suite() throws -> (UserDefaults, () -> Void) {
        let name = "hspace-prefs-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }

    private var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Keys that belong to this Mac or to this moment, not to the owner's taste
    private let staysHere: Set<String> = ["recentTags", "fdaPromptDismissed"]

    @Test func everyPreferenceTravelsUnlessItBelongsToThisMac() throws {
        let text = try String(contentsOf: sourcesRoot.appendingPathComponent("Sources/HSpaceApp/Preferences.swift"), encoding: .utf8)
        let regex = try NSRegularExpression(pattern: "forKey: \"([A-Za-z.]+)\"")
        let keys = Set(regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            String(text[Range($0.range(at: 1), in: text)!])
        })
        #expect(keys.count > 30)
        let kinds = PreferencesCatalog.kinds
        for key in keys.subtracting(staysHere) { #expect(kinds[key] != nil, "\(key) is not exported") }
        for key in staysHere { #expect(kinds[key] == nil) }
    }

    @Test func noSecretAndNoWindowStateTravels() {
        let kinds = PreferencesCatalog.kinds
        #expect(!kinds.keys.contains(where: PreferenceSchema.looksSecret))
        for key in ["windowFrame", "sidebarWidth", "sidebarCollapsed", "seedsMergedV2"] { #expect(kinds[key] == nil) }
        #expect(KeyBindings.registry.allSatisfy { kinds["kb.\($0.id)"] != nil })
    }

    @Test func todaysDefaultsFitTheSchema() {
        let schema = PreferencesCatalog.schema()
        #expect(schema.validated("archiveFormat", .text(Preferences.archiveFormat)) != nil)
        #expect(schema.validated("terminalChoice", .text("com.googlecode.iterm2")) != nil)
        #expect(schema.validated("panelActions", .list(PanelAction.defaultIDs)) != nil)
        #expect(schema.validated("visibleColumns", .list(["dateModified", "size", "kind"])) != nil)
        #expect(schema.validated("globalHotkey", .text("1048576|49|⌘Space")) != nil)
        #expect(schema.validated("kb.newTab", .text("1048576|t")) != nil)
        #expect(schema.validated("defaultLayout", .integer(PaneLayout.quad.rawValue)) != nil)
        #expect(schema.validated("defaultLayout", .integer(0)) == nil)
    }

    @Test func settingsCrossToAnotherMacUnchanged() throws {
        let (source, dropSource) = try suite()
        defer { dropSource() }
        let (target, dropTarget) = try suite()
        defer { dropTarget() }
        let dir = try FaultFixture.tempDir("hspace-prefs")
        defer { FaultFixture.remove(dir) }
        source.set(false, forKey: "foldersFirst")
        source.set(13, forKey: "listFontSize")
        source.set(0.2, forKey: "inactivePaneDimming")
        source.set("dark", forKey: "appearanceMode")
        source.set(["size"], forKey: "visibleColumns")
        source.set("1048576|t", forKey: "kb.newTab")
        source.set(["cut"], forKey: ContextMenuCustomization.defaultsKeys(.item).hidden)
        source.set("{0, 0, 10, 10}", forKey: "windowFrame")

        let url = dir.appendingPathComponent("prefs.json")
        let left = try PreferencesTransfer(defaults: source).export(to: url)
        #expect(left.isEmpty)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("windowFrame"))

        target.set(true, forKey: "dragShake")   // not in the file: goes back to its default
        target.set("kept", forKey: "windowFrame")
        let transfer = PreferencesTransfer(defaults: target)
        transfer.apply(try PreferencesFile.read(from: url, schema: transfer.schema))
        #expect(target.object(forKey: "foldersFirst") as? Bool == false)
        #expect(target.integer(forKey: "listFontSize") == 13)
        #expect(target.double(forKey: "inactivePaneDimming") == 0.2)
        #expect(target.string(forKey: "appearanceMode") == "dark")
        #expect(target.stringArray(forKey: "visibleColumns") == ["size"])
        #expect(target.string(forKey: "kb.newTab") == "1048576|t")
        #expect(target.stringArray(forKey: ContextMenuCustomization.defaultsKeys(.item).hidden) == ["cut"])
        #expect(target.object(forKey: "dragShake") == nil)
        #expect(target.string(forKey: "windowFrame") == "kept")
        #expect(PreferencesTransfer(defaults: target).snapshot() == PreferencesTransfer(defaults: source).snapshot())
    }

    @Test func aBadFileChangesNothing() throws {
        let (defaults, drop) = try suite()
        defer { drop() }
        let dir = try FaultFixture.tempDir("hspace-prefs")
        defer { FaultFixture.remove(dir) }
        defaults.set(12, forKey: "listFontSize")
        defaults.set(true, forKey: "dragShake")
        let before = PreferencesTransfer(defaults: defaults).snapshot()
        let url = dir.appendingPathComponent("bad.json")
        let body = "{\"format\":\"hspace-preferences\",\"version\":1,\"settings\":{\"listFontSize\":14,\"dragShake\":false,\"listGrouping\":\"yes\"}}"
        try FaultFixture.write(Data(body.utf8), to: url)
        let transfer = PreferencesTransfer(defaults: defaults)
        #expect(throws: PreferencesTransferError.self) {
            transfer.apply(try PreferencesFile.read(from: url, schema: transfer.schema))
        }
        #expect(transfer.snapshot() == before)
    }

    @Test func aFileWithAnArchivePasswordIsRefused() throws {
        let body = "{\"format\":\"hspace-preferences\",\"version\":1,\"settings\":{\"archivePasswords\":[\"hunter2\"]}}"
        #expect(throws: PreferencesTransferError.self) {
            try PreferencesFile.decode(Data(body.utf8), schema: PreferencesCatalog.schema())
        }
    }

    @Test func aStoredValueOfTheWrongTypeIsNotExported() throws {
        let (defaults, drop) = try suite()
        defer { drop() }
        defaults.set("big", forKey: "listFontSize")
        defaults.set(40, forKey: "listGrouping")
        defaults.set(99, forKey: "maxConcurrentOperations")
        let transfer = PreferencesTransfer(defaults: defaults)
        #expect(transfer.snapshot()["listFontSize"] == nil)
        #expect(transfer.snapshot()["listGrouping"] == nil)
        let dir = try FaultFixture.tempDir("hspace-prefs")
        defer { FaultFixture.remove(dir) }
        #expect(try transfer.export(to: dir.appendingPathComponent("p.json")) == ["maxConcurrentOperations"])
    }

    @Test func theBackupFailsLoudlyWhenTheFolderIsReadOnly() throws {
        let (defaults, drop) = try suite()
        defer { drop() }
        let dir = try FaultFixture.tempDir("hspace-prefs")
        defer { FaultFixture.remove(dir) }
        let transfer = PreferencesTransfer(defaults: defaults)
        // By hand: the fixture's async helper cannot carry a main-actor value
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        #expect(throws: PreferencesTransferError.self) { try transfer.backUp(in: dir) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        let url = try transfer.backUp(in: dir)
        #expect(try PreferencesFile.read(from: url, schema: transfer.schema).values == transfer.snapshot())
    }
}
