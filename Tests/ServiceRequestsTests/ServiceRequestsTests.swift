import Foundation
import HSpaceTestSupport
import ServiceRequests
import Testing

@Suite struct ServicePlanTests {
    private func fixture() throws -> (dir: URL, file: URL, folder: URL) {
        let dir = try FaultFixture.tempDir("hspace-service")
        let file = dir.appendingPathComponent("a.txt")
        let folder = dir.appendingPathComponent("Folder")
        try FaultFixture.write(to: file)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (dir, file, folder)
    }

    @Test func renameAndStashTakeFilesAndFoldersOnceEach() throws {
        let (dir, file, folder) = try fixture()
        defer { FaultFixture.remove(dir) }
        for service in [HSpaceService.batchRename, .addToStash] {
            let items = try ServicePlan.items(for: service, from: [folder, file, file]).get()
            #expect(items.map(\.url) == [folder.standardizedFileURL, file.standardizedFileURL])
            #expect(items.map(\.isDirectory) == [true, false])
            #expect(items[1].modified != nil)
        }
    }

    @Test func hashesSkipFolders() throws {
        let (dir, file, folder) = try fixture()
        defer { FaultFixture.remove(dir) }
        #expect(try ServicePlan.items(for: .showHashes, from: [folder, file]).get().map(\.url) == [file.standardizedFileURL])
        #expect(ServicePlan.items(for: .showHashes, from: [folder]) == .failure(.onlyFolders))
    }

    @Test func aVanishedItemIsNamed() throws {
        let (dir, file, _) = try fixture()
        defer { FaultFixture.remove(dir) }
        let gone = dir.appendingPathComponent("gone.txt")
        #expect(ServicePlan.items(for: .batchRename, from: [file, gone]) == .failure(.missing("gone.txt")))
    }

    @Test func webLinksAndNothingAreRefused() {
        #expect(ServicePlan.items(for: .addToStash, from: []) == .failure(.nothingUsable))
        #expect(ServicePlan.items(for: .addToStash, from: [URL(string: "https://example.com")!]) == .failure(.nothingUsable))
    }

    @Test func anUnreadableFolderStillCounts() async throws {
        // Its own metadata is readable even when its contents are not: renaming it works as in a pane
        let (dir, _, folder) = try fixture()
        defer { FaultFixture.remove(dir) }
        let result = try await FaultFixture.withUnreadable(folder) {
            ServicePlan.items(for: .batchRename, from: [folder])
        }
        #expect(try result.get().count == 1)
    }

    @Test func messagesAreDistinct() {
        #expect(Set(HSpaceService.allCases.map(\.message)).count == HSpaceService.allCases.count)
    }
}
