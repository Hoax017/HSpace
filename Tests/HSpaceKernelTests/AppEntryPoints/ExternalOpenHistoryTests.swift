import Foundation
import Testing

@Suite struct ExternalOpenHistoryTests {
    private let key = "debug.lastExternalOpen"

    @Test func thePathIsNoLongerWritten() throws {
        let writers = try AppSources.all().filter { $0.text.contains("set(") && $0.text.contains("forKey: \"\(key)\"") }
        #expect(writers.map(\.name) == [])
    }

    @Test func theAppClearsWhatOlderVersionsStored() throws {
        let delegate = try #require(try AppSources.all().first { $0.name == "AppDelegate.swift" })
        #expect(delegate.text.contains("ExternalOpenHistory.purgeStoredPath(from: .standard)"))
    }

    @Test func purgingRemovesThePathAndNothingElse() throws {
        let name = "com.hoax017.hspace.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("1|/Users/someone/private.txt", forKey: key)
        defaults.set("kept", forKey: "other")
        ExternalOpenHistory.purgeStoredPath(from: defaults)
        #expect(defaults.object(forKey: key) == nil)
        #expect(defaults.string(forKey: "other") == "kept")
    }
}
