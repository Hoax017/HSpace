import Foundation
@testable import HSpaceApp
import Testing

@Suite struct TestRunStoreIsolation {
    @Test func storesOnlyLearnTheirDirectoryFromAppDelegate() throws {
        // AppDelegate.supportDirectory is what moves a test run to its temporary directory
        let direct = try AppSources.all().filter { $0.text.contains(".applicationSupportDirectory") }.map(\.name)
        #expect(direct == ["AppDelegate.swift"])
    }

    @Test func theSeedFlagIsNotSharedWithTheRealBookmarks() throws {
        let sidebar = try #require(try AppSources.all().first { $0.name == "SidebarModel.swift" })
        #expect(!sidebar.text.contains("forKey: \"seedsMergedV2\""))
    }
}
