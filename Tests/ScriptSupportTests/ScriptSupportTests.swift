import Foundation
import HSpaceTestSupport
import ScriptSupport
import Testing

@Suite struct ScriptLocationTests {
    @Test func aFolderIsShownAndAFileIsSelectedInItsFolder() throws {
        let dir = try FaultFixture.tempDir()
        defer { FaultFixture.remove(dir) }
        let file = dir.appendingPathComponent("a.txt")
        try FaultFixture.write(to: file)
        #expect(ScriptPlan.location(for: dir) == .success(.folder(dir.standardizedFileURL)))
        #expect(ScriptPlan.location(for: file) == .success(.item(file.standardizedFileURL, in: dir.standardizedFileURL)))
    }

    @Test func aPackageIsSelectedNotEntered() throws {
        let dir = try FaultFixture.tempDir()
        defer { FaultFixture.remove(dir) }
        let app = dir.appendingPathComponent("Tool.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        #expect(ScriptPlan.location(for: app) == .success(.item(app.standardizedFileURL, in: dir.standardizedFileURL)))
    }

    @Test func aMissingItemIsFileNotFound() throws {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        guard case .failure(let error) = ScriptPlan.location(for: missing) else { Issue.record("went to a missing item"); return }
        #expect(error.code == -43)
    }

    @Test func aWebAddressIsRefused() throws {
        guard case .failure(let error) = ScriptPlan.location(for: URL(string: "https://example.com")!) else {
            Issue.record("went to a web address")
            return
        }
        #expect(error.code == -50)
    }

    @Test func anUnreadableFolderStillResolves() async throws {
        // The pane shows the folder's own error, as when the user goes there
        let dir = try FaultFixture.tempDir()
        defer { FaultFixture.remove(dir) }
        let locked = dir.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try await FaultFixture.withUnreadable(locked) {
            #expect(ScriptPlan.location(for: locked) == .success(.folder(locked.standardizedFileURL)))
        }
    }
}

@Suite struct ScriptSelectionTests {
    @Test func itemsInTheFolderAreSelectedOnceEach() throws {
        let dir = try FaultFixture.tempDir()
        defer { FaultFixture.remove(dir) }
        let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b")
        try FaultFixture.write(to: a)
        try FaultFixture.write(to: b)
        #expect(ScriptPlan.selection([b, a, b], in: dir) == .success([b.standardizedFileURL, a.standardizedFileURL]))
        #expect(ScriptPlan.selection([], in: dir) == .success([]))
    }

    @Test func anItemElsewhereIsNoSuchObject() throws {
        let dir = try FaultFixture.tempDir()
        defer { FaultFixture.remove(dir) }
        let deep = dir.appendingPathComponent("sub/c")
        try FaultFixture.write(to: deep)
        guard case .failure(let error) = ScriptPlan.selection([deep], in: dir) else { Issue.record("selected out of folder"); return }
        #expect(error.code == -1728)
    }

    @Test func aMissingItemIsFileNotFound() throws {
        let dir = try FaultFixture.tempDir()
        defer { FaultFixture.remove(dir) }
        guard case .failure(let error) = ScriptPlan.selection([dir.appendingPathComponent("gone")], in: dir) else {
            Issue.record("selected a missing item")
            return
        }
        #expect(error.code == -43)
    }
}

@Suite struct ScriptStashTests {
    @Test func filesOnlyEachOnce() {
        let a = URL(fileURLWithPath: "/a"), b = URL(fileURLWithPath: "/b")
        #expect(ScriptPlan.stashItems([a, b, URL(fileURLWithPath: "/a/../a")]) == .success([a, b]))
    }

    @Test func emptyOrWebIsRefused() {
        #expect(ScriptPlan.stashItems([]).map { _ in 0 } == .failure(.badValue("Name at least one file or folder.")))
        guard case .failure(let error) = ScriptPlan.stashItems([URL(string: "https://example.com")!]) else {
            Issue.record("stashed a web address")
            return
        }
        #expect(error.code == -50)
    }

    @Test func paneNumbersAreOneBased() {
        #expect(ScriptPlan.paneIndex(1, count: 2) == .success(0))
        #expect(ScriptPlan.paneIndex(2, count: 2) == .success(1))
        for bad in [0, 3, -1] {
            guard case .failure(let error) = ScriptPlan.paneIndex(bad, count: 2) else { Issue.record("pane \(bad)"); continue }
            #expect(error.code == -50)
        }
        guard case .failure = ScriptPlan.paneIndex(1, count: 0) else { Issue.record("pane in an empty window"); return }
    }
}
