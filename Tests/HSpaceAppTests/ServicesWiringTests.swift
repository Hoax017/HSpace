import AppKit
import HSpaceTestSupport
import ServiceRequests
import Testing
@testable import HSpaceApp

private let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@MainActor @Suite struct ServicesWiringTests {
    private func services() throws -> [[String: Any]] {
        let data = try Data(contentsOf: root.appendingPathComponent("Support/Info.plist"))
        let info = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        return try #require(info["NSServices"] as? [[String: Any]])
    }

    @Test func everyServiceIsListedAndAnswered() throws {
        let listed = try services()
        for service in HSpaceService.allCases {
            let entry = try #require(listed.first { $0["NSMessage"] as? String == service.message }, "\(service)")
            #expect(entry["NSPortName"] as? String == "HSpace")
            let title = (entry["NSMenuItem"] as? [String: String])?["default"] ?? ""
            #expect(title.contains("HSpace"), "\(service) title")
            let answers = AppDelegate.instancesRespond(to: NSSelectorFromString("\(service.message):userData:error:"))
            #expect(answers, "\(service)")
        }
    }

    @Test func hashesAreOfferedForFilesOnly() throws {
        let hash = try #require(try services().first { $0["NSMessage"] as? String == HSpaceService.showHashes.message })
        #expect(hash["NSSendFileTypes"] as? [String] == ["public.data"])
    }

    @Test func renameTakesTheItemsAsTheyAre() throws {
        let dir = try FaultFixture.tempDir("hspace-service")
        defer { FaultFixture.remove(dir) }
        let file = dir.appendingPathComponent("a.txt")
        try FaultFixture.write(to: file)
        let items = try ServicePlan.items(for: .batchRename, from: [file, dir]).get()
        let fileItems = try ServiceRouting.renameItems(items).get()
        #expect(fileItems.map(\.name) == ["a.txt", dir.lastPathComponent])
        #expect(fileItems.map(\.isDirectory) == [false, true])
        #expect(fileItems[0].modified == items[0].modified)
    }

    @Test func itemsInTheTrashAreNotRenamed() throws {
        let trashed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/old.txt")
        let item = ServiceItem(url: trashed, isDirectory: false, isPackage: false, created: nil, modified: nil)
        #expect(ServiceRouting.renameItems([item]) == .failure(.inTrash))
    }

    @Test func everyRefusalHasAString() throws {
        let table = try #require(NSDictionary(contentsOf: root.appendingPathComponent("Resources/en.lproj/Localizable.strings")))
        for key in ["service.nothingUsable", "service.onlyFolders", "service.missing", "service.inTrash", "service.busy"] {
            #expect(table[key] != nil, "\(key)")
        }
    }
}
