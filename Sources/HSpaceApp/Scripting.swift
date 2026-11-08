import AppKit
import ScriptSupport

// AppleScript support (L62). Support/HSpace.sdef names these classes and keys. Cocoa scripting calls them on the main
// thread. Each object is a thin view onto a live window or pane: it is made on demand and holds nothing of its own.

/// Tells the running script what went wrong. Tests swap in their own reporter.
@MainActor
var scriptErrorReporter: (ScriptError) -> Void = { error in
    guard let command = NSScriptCommand.current() else { return }
    command.scriptErrorNumber = error.code
    command.scriptErrorString = error.message
}

@MainActor
private func fail(_ error: ScriptError) {
    scriptErrorReporter(error)
}

extension AppDelegate {
    func application(_ sender: NSApplication, delegateHandlesKey key: String) -> Bool {
        ["scriptBrowserWindows", "scriptStashItems"].contains(key)
    }

    /// Main windows front to back, then any that are hidden
    var scriptWindowControllers: [MainWindowController] {
        let live = liveMainWindows
        let ordered = NSApp.orderedWindows.compactMap { window in live.first { $0.window === window } }
        return ordered + live.filter { wc in !ordered.contains { $0 === wc } }
    }

    @objc var scriptBrowserWindows: [ScriptBrowserWindow] {
        scriptWindowControllers.map(ScriptBrowserWindow.init)
    }

    @objc var scriptStashItems: [URL] {
        guard let shelf = scriptWindowControllers.first?.stashShelf else { return [] }
        return shelf.items.compactMap { shelf.store.resolve($0) }
    }
}

@MainActor
@objc(HSpaceScriptBrowserWindow)
final class ScriptBrowserWindow: NSObject {
    let controller: MainWindowController
    /// The window number, which stays the same while the window is open
    @objc let uniqueID: Int

    init(_ controller: MainWindowController) {
        self.controller = controller
        uniqueID = controller.window?.windowNumber ?? 0
    }

    @objc var name: String {
        FileManager.default.displayName(atPath: controller.grid.activePane.activeTab.browser.current.path)
    }

    @objc var panes: [ScriptPane] {
        controller.grid.visiblePanes.indices.map { ScriptPane(grid: controller.grid, index: $0, windowID: uniqueID) }
    }

    @objc var activePane: ScriptPane {
        ScriptPane(grid: controller.grid, index: controller.grid.activePaneIndex, windowID: uniqueID)
    }

    nonisolated override var objectSpecifier: NSScriptObjectSpecifier? {
        Self.specifier(uniqueID: uniqueID)
    }

    nonisolated static func specifier(uniqueID: Int) -> NSScriptObjectSpecifier? {
        guard let app = NSScriptClassDescription(for: NSApplication.self) else { return nil }
        return NSUniqueIDSpecifier(containerClassDescription: app, containerSpecifier: nil,
                                   key: "scriptBrowserWindows", uniqueID: uniqueID)
    }
}

@MainActor
@objc(HSpaceScriptPane)
final class ScriptPane: NSObject {
    private let grid: PaneGridController
    private let index: Int
    private let windowID: Int

    init(grid: PaneGridController, index: Int, windowID: Int) {
        self.grid = grid
        self.index = index
        self.windowID = windowID
    }

    /// nil once the layout no longer has this pane
    private var pane: PaneViewController? {
        let panes = grid.visiblePanes
        return panes.indices.contains(index) ? panes[index] : nil
    }

    private func livePane() -> PaneViewController? {
        guard let pane else {
            fail(.badValue("This pane was closed by a layout change."))
            return nil
        }
        return pane
    }

    @objc var paneNumber: Int { index + 1 }

    @objc var location: URL {
        get { pane?.activeTab.browser.current ?? URL(fileURLWithPath: "/") }
        set {
            guard let pane = livePane() else { return }
            switch ScriptPlan.location(for: newValue) {
            case .success(.folder(let folder)):
                if pane.activeTab.browser.current.standardizedFileURL != folder { pane.navigate(to: folder) }
            case .success(.item(let item, in: let folder)):
                if pane.activeTab.browser.current.standardizedFileURL != folder {
                    pane.navigate(to: folder)
                    pane.reveal(item)
                } else {
                    pane.selectItems([item])
                }
            case .failure(let error):
                fail(error)
            }
        }
    }

    @objc var selectedItems: [URL] {
        get { pane?.currentSelectedItems().map(\.url) ?? [] }
        set {
            guard let pane = livePane() else { return }
            switch ScriptPlan.selection(newValue, in: pane.activeTab.browser.current) {
            case .success(let items): pane.selectItems(items)
            case .failure(let error): fail(error)
            }
        }
    }

    @objc var isActive: Bool {
        get { grid.activePaneIndex == index }
        set {
            guard livePane() != nil else { return }
            if newValue {
                grid.setActivePane(index)
            } else if grid.activePaneIndex == index {
                fail(.badValue("Focus another pane instead: one pane always has the focus."))
            }
        }
    }

    nonisolated override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let container = NSScriptClassDescription(for: ScriptBrowserWindow.self) else { return nil }
        return NSIndexSpecifier(containerClassDescription: container,
                                containerSpecifier: ScriptBrowserWindow.specifier(uniqueID: windowID),
                                key: "panes", index: index)
    }
}

/// `add to stash` and `remove from stash`: the files named, as a list or one alone
private func scriptFiles(of command: NSScriptCommand) -> Result<[URL], ScriptError> {
    let given: [URL]
    switch command.directParameter {
    case let url as URL: given = [url]
    case let urls as [URL]: given = urls
    case let list as [Any]: given = list.compactMap { $0 as? URL }
    default: given = []
    }
    return ScriptPlan.stashItems(given)
}

@MainActor
private var frontShelf: StashShelfController? {
    (NSApp.delegate as? AppDelegate)?.scriptWindowControllers.first?.stashShelf
}

@objc(HSpaceScriptAddToStash)
final class ScriptAddToStash: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let files = scriptFiles(of: self)
        let count: Int? = MainActor.assumeIsolated {
            guard let shelf = frontShelf else { fail(.noWindow); return nil }
            switch files {
            case .success(let urls):
                shelf.add(urls)
                return urls.count
            case .failure(let error):
                fail(error)
                return nil
            }
        }
        return count
    }
}

@objc(HSpaceScriptRemoveFromStash)
final class ScriptRemoveFromStash: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let files = scriptFiles(of: self)
        let count: Int? = MainActor.assumeIsolated {
            guard let shelf = frontShelf else { fail(.noWindow); return nil }
            switch files {
            case .success(let urls):
                let wanted = Set(urls.map(\.standardizedFileURL.path))
                let ids = shelf.items.filter { item in
                    shelf.store.resolve(item).map { wanted.contains($0.standardizedFileURL.path) } ?? false
                }.map(\.id)
                shelf.remove(ids: ids)
                return ids.count
            case .failure(let error):
                fail(error)
                return nil
            }
        }
        return count
    }
}
