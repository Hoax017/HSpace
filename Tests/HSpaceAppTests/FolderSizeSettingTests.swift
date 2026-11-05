import AppKit
import FolderSize
import HSpaceContracts
import HSpaceTestSupport
import Testing
@testable import HSpaceApp

/// Serialized: the setting is app-wide
@MainActor @Suite(.serialized) struct FolderSizeSettingTests {
    /// A list in a real window, because decorations run only for what is on screen
    private func showList(of dir: URL) async throws -> (window: NSWindow, list: FileListViewController, model: DirectoryViewModel) {
        let model = DirectoryViewModel(directory: dir)
        let list = FileListViewController(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentViewController = list
        for _ in 0..<300 where model.items.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        window.setContentSize(NSSize(width: 600, height: 400))
        window.layoutIfNeeded()
        list.tableView.layoutSubtreeIfNeeded()
        list.refreshVisibleDecorations()
        return (window, list, model)
    }

    private func sizeShown(_ list: FileListViewController) -> String? {
        let column = list.tableView.column(withIdentifier: .init("size"))
        guard column >= 0 else { return nil }
        return (list.tableView.view(atColumn: column, row: 0, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue
    }

    private func withMode(_ mode: FolderSizeMode, _ body: () async throws -> Void) async rethrows {
        let previous = Preferences.folderSizeMode
        let columns = Preferences.visibleColumns
        Preferences.folderSizeMode = mode
        Preferences.visibleColumns = ["size"]
        defer {
            Preferences.folderSizeMode = previous
            Preferences.visibleColumns = columns
        }
        try await body()
    }

    @Test func aFolderGetsItsSizeWhenTheSettingWantsIt() async throws {
        let dir = try FaultFixture.tempDir("hspace-foldersize")
        defer { FaultFixture.remove(dir) }
        try FaultFixture.write(Data(repeating: 1, count: 40_000), to: dir.appendingPathComponent("sub/big"))
        try await withMode(.all) {
            let (window, list, model) = try await showList(of: dir)
            defer { model.stopWatching(); window.close() }
            let item = try #require(model.items.first)
            for _ in 0..<300 where list.knownSize(of: item) == nil { try await Task.sleep(for: .milliseconds(10)) }
            #expect((list.knownSize(of: item) ?? 0) >= 40_000)
        }
    }

    @Test func neverLeavesAPlaceholderAndWalksNothing() async throws {
        let dir = try FaultFixture.tempDir("hspace-foldersize")
        defer { FaultFixture.remove(dir) }
        try FaultFixture.write(to: dir.appendingPathComponent("sub/a"))
        try await withMode(.never) {
            let (window, list, model) = try await showList(of: dir)
            defer { model.stopWatching(); window.close() }
            try await Task.sleep(for: .milliseconds(100))
            #expect(list.knownSize(of: try #require(model.items.first)) == nil)
        }
    }

    @Test func anUnreadableFolderEndsAsAPlaceholderNotALoop() async throws {
        let dir = try FaultFixture.tempDir("hspace-foldersize")
        defer { FaultFixture.remove(dir) }
        let locked = dir.appendingPathComponent("locked")
        try FaultFixture.write(to: locked.appendingPathComponent("a"))
        chmod(locked.path, 0o000)
        defer { chmod(locked.path, 0o755) }
        try await withMode(.all) {
            let (window, list, model) = try await showList(of: dir)
            defer { model.stopWatching(); window.close() }
            for _ in 0..<300 where list.sizeRequestsInFlight > 0 || sizeShown(list) == "…" {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(list.sizeRequestsInFlight == 0)
        }
    }

    @Test func aFileListsItsOwnSizeWhateverTheSetting() async throws {
        let dir = try FaultFixture.tempDir("hspace-foldersize")
        defer { FaultFixture.remove(dir) }
        try FaultFixture.write(Data("12345".utf8), to: dir.appendingPathComponent("f"))
        try await withMode(.never) {
            let (window, list, model) = try await showList(of: dir)
            defer { model.stopWatching(); window.close() }
            #expect(list.knownSize(of: try #require(model.items.first)) == 5)
        }
    }
}
