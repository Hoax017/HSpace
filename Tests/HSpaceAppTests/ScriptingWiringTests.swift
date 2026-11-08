import AppKit
import HSpaceTestSupport
import ScriptSupport
import Testing
@testable import HSpaceApp

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The dictionary names classes and keys by string: a rename in code would break scripts with no compile error
@MainActor @Suite struct ScriptDictionaryTests {
    private func dictionary() throws -> XMLDocument {
        try XMLDocument(contentsOf: repositoryRoot.appendingPathComponent("Support/HSpace.sdef"))
    }

    private func nodes(_ xpath: String) throws -> [XMLElement] {
        try dictionary().nodes(forXPath: xpath).compactMap { $0 as? XMLElement }
    }

    @Test func theInfoPlistPointsAtTheDictionary() throws {
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent("Support/Info.plist"))
        let info = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(info["OSAScriptingDefinition"] as? String == "HSpace.sdef")
        #expect(info["NSAppleScriptEnabled"] as? Bool == true)
    }

    @Test func everyClassAndKeyExists() throws {
        let classes = try nodes("//suite[@code='HSpc']/class")
        #expect(classes.count == 2)
        for element in classes {
            let name = try #require(element.elements(forName: "cocoa").first?.attribute(forName: "class")?.stringValue)
            guard let cls = NSClassFromString(name) else { Issue.record("no class \(name)"); continue }
            for child in element.elements(forName: "property") + element.elements(forName: "element") {
                let key = try #require(child.elements(forName: "cocoa").first?.attribute(forName: "key")?.stringValue)
                let getter = cls.instancesRespond(to: NSSelectorFromString(key))
                #expect(getter, "\(name).\(key)")
                if child.attribute(forName: "access")?.stringValue == "rw" {
                    let setter = "set" + key.prefix(1).uppercased() + key.dropFirst() + ":"
                    let settable = cls.instancesRespond(to: NSSelectorFromString(setter))
                    #expect(settable, "\(name).\(setter)")
                }
            }
        }
    }

    @Test func theApplicationKeysAreHandledByTheDelegate() throws {
        let keys = try nodes("//class-extension[@extends='application']//cocoa").compactMap { $0.attribute(forName: "key")?.stringValue }
        #expect(keys.count == 2)
        let delegate = AppDelegate()
        for key in keys {
            #expect(delegate.application(NSApplication.shared, delegateHandlesKey: key), "\(key)")
            #expect(AppDelegate.instancesRespond(to: NSSelectorFromString(key)), "\(key)")
        }
    }

    @Test func everyCommandHasItsClass() throws {
        let commands = try nodes("//suite[@code='HSpc']/command")
        #expect(commands.count == 2)
        for command in commands {
            let name = try #require(command.elements(forName: "cocoa").first?.attribute(forName: "class")?.stringValue)
            guard let cls = NSClassFromString(name) else { Issue.record("no class \(name)"); continue }
            let isCommand = cls.isSubclass(of: NSScriptCommand.self)
            #expect(isCommand, "\(name)")
        }
    }

    @Test func codesAreUniqueAndFourCharacters() throws {
        let codes = try nodes("//suite[@code='HSpc']//*[@code]").compactMap { $0.attribute(forName: "code")?.stringValue }
        let classAndPropertyCodes = codes.filter { $0.count == 4 }
        let commandCodes = codes.filter { $0.count == 8 }
        #expect(classAndPropertyCodes.count + commandCodes.count == codes.count)
        #expect(Set(commandCodes).count == commandCodes.count)
    }
}

/// Serialized: the error reporter is app-wide
@MainActor @Suite(.serialized) struct ScriptPaneTests {
    private func withPane(_ body: @MainActor (ScriptPane, PaneGridController, URL) async throws -> Void) async throws {
        let dir = try FaultFixture.tempDir("hspace-script")
        defer { FaultFixture.remove(dir) }
        try FaultFixture.write(to: dir.appendingPathComponent("top.txt"))
        try FaultFixture.write(to: dir.appendingPathComponent("sub/a.txt"))
        try FaultFixture.write(to: dir.appendingPathComponent("sub/b.txt"))
        let grid = PaneGridController(initialDirectory: dir)
        _ = grid.view
        defer { grid.visiblePanes.forEach { $0.activeTab.model.stopWatching() } }
        try await body(ScriptPane(grid: grid, index: 0, windowID: 7), grid, dir)
    }

    @Test func pathGoesToAFolderAndShowsAFileSelected() async throws {
        try await withPane { pane, grid, dir in
            #expect(pane.location.standardizedFileURL == dir.standardizedFileURL)
            let sub = dir.appendingPathComponent("sub")
            pane.location = sub
            #expect(grid.activePane.activeTab.browser.current.standardizedFileURL == sub.standardizedFileURL)

            let file = sub.appendingPathComponent("b.txt")
            pane.location = dir.appendingPathComponent("top.txt")
            await eventually("top.txt selected in its folder") {
                pane.selectedItems.map(\.lastPathComponent) == ["top.txt"]
            }
            pane.location = sub
            await eventually("sub listed") {
                grid.activePane.activeTab.model.items.contains { $0.url.lastPathComponent == "b.txt" }
            }
            pane.selectedItems = [file]
            #expect(pane.selectedItems.map(\.lastPathComponent) == ["b.txt"])
            pane.selectedItems = []
            #expect(pane.selectedItems.isEmpty)
        }
    }

    @Test func badRequestsReachTheScriptAndChangeNothing() async throws {
        let box = ErrorBox()
        let previous = scriptErrorReporter
        defer { scriptErrorReporter = previous }
        let dir = try FaultFixture.tempDir("hspace-script")
        defer { FaultFixture.remove(dir) }
        try FaultFixture.write(to: dir.appendingPathComponent("a.txt"))
        try FaultFixture.write(to: dir.appendingPathComponent("sub/inner.txt"))
        let grid = PaneGridController(initialDirectory: dir)
        _ = grid.view
        defer { grid.visiblePanes.forEach { $0.activeTab.model.stopWatching() } }
        scriptErrorReporter = { box.errors.append($0) }
        let pane = ScriptPane(grid: grid, index: 0, windowID: 7)

        pane.location = dir.appendingPathComponent("missing")
        pane.selectedItems = [dir.appendingPathComponent("sub/inner.txt")]
        pane.isActive = false
        #expect(box.errors.map(\.code) == [-43, -1728, -50])
        #expect(grid.activePane.activeTab.browser.current.standardizedFileURL == dir.standardizedFileURL)

        let gone = ScriptPane(grid: grid, index: 3, windowID: 7)
        gone.location = dir
        #expect(box.errors.last?.code == -50)
    }

    @Test func activeFocusesThePane() async throws {
        try await withPane { _, grid, _ in
            grid.apply(layout: .dualH)
            let second = ScriptPane(grid: grid, index: 1, windowID: 7)
            #expect(!second.isActive)
            second.isActive = true
            #expect(grid.activePaneIndex == 1)
            #expect(second.paneNumber == 2)
        }
    }
}

@MainActor
private final class ErrorBox {
    var errors: [ScriptError] = []
}
