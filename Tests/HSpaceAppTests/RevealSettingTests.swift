import Foundation
@testable import HSpaceApp
import Testing

/// Runs against a private application id: the real NSFileViewer key is global to the user and must never be touched here.
@Suite struct RevealSettingRestore {
    private let setting = RevealSetting(applicationID: "com.hoax017.hspace.tests.\(UUID().uuidString)" as CFString)

    @Test func restoreClearsOurOwnTakeover() throws {
        defer { setting.set(handler: nil) }
        setting.set(handler: "com.hoax017.hspace")
        try setting.restoreSystemDefault()
        #expect(setting.handler == nil)
    }

    @Test func restoreClearsAStaleHandlerFromADeletedApp() throws {
        defer { setting.set(handler: nil) }
        setting.set(handler: "com.example.deleted-app")
        try setting.restoreSystemDefault()
        #expect(setting.handler == nil)
    }

    @Test func restoreIsSafeWhenFinderAlreadyHandlesReveal() throws {
        try setting.restoreSystemDefault()
        #expect(setting.handler == nil)
    }

    @Test func theFailureNamesTheAppStillHoldingReveal() throws {
        #expect(RevealSettingError.notRestored(handler: "com.example.app").message == L10n.f("reveal.notRestored", "com.example.app"))
        // The test bundle has no app strings, so each shipped table proves the handler reaches the message
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources")
        for language in try FileManager.default.contentsOfDirectory(atPath: resources.path) where language.hasSuffix(".lproj") {
            let table = try #require(Bundle(path: resources.appendingPathComponent(language).path))
            let format = L10n.lookup("reveal.notRestored", in: table, fallback: nil)
            #expect(String(format: format, "com.example.app").contains("com.example.app"), "\(language)")
        }
    }

    @Test func theRealFunctionTargetsTheGlobalKey() throws {
        // Only the wiring is read here; calling it would change the user's system.
        let source = try #require(try AppSources.all().first { $0.name == "FinderIntegration.swift" })
        #expect(source.text.contains("RevealSetting.system.restoreSystemDefault()"))
    }
}
