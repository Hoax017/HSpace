import AppKit
import QuickLauncher
import QuickLocations
import Testing
@testable import HSpaceApp

@MainActor
private final class Target: NSObject, NSMenuItemValidation {
    var fired: [String] = []
    var enabled = true

    @objc func go(_ sender: NSMenuItem) { fired.append(sender.title) }
    func validateMenuItem(_ item: NSMenuItem) -> Bool { enabled }
}

private final class MemoryHistory: CommandHistoryStoring, @unchecked Sendable {
    var ids: [String] = []
    var failure: LauncherError?
    func recent() -> [String] { ids }
    func record(_ id: String) throws {
        if let failure { throw failure }
        ids.insert(id, at: 0)
    }
    func takeProblem() -> LauncherError? { nil }
}

@MainActor @Suite struct MenuCommandTests {
    private let target = Target()

    /// NSMenu validates nothing until the application object exists
    init() { _ = NSApplication.shared }

    private func menu(target: Target) -> NSMenu {
        let main = NSMenu()
        let view = main.addItem(withTitle: "View", action: nil, keyEquivalent: "")
        let viewMenu = NSMenu(title: "View")
        view.submenu = viewMenu
        let refresh = viewMenu.addItem(withTitle: "Refresh", action: #selector(Target.go(_:)), keyEquivalent: "r")
        refresh.target = target
        viewMenu.addItem(.separator())
        let hidden = viewMenu.addItem(withTitle: "Hidden", action: #selector(Target.go(_:)), keyEquivalent: "")
        hidden.target = target
        hidden.isHidden = true
        viewMenu.addItem(withTitle: "No Action", action: nil, keyEquivalent: "")
        let layout = viewMenu.addItem(withTitle: "Layout", action: nil, keyEquivalent: "")
        let layoutMenu = NSMenu(title: "Layout")
        layout.submenu = layoutMenu
        layoutMenu.addItem(withTitle: "Dual", action: #selector(Target.go(_:)), keyEquivalent: "").target = target
        return main
    }

    @Test func itWalksSubmenusAndSkipsWhatIsNotACommand() {
        let commands = MenuCommand.collect(from: menu(target: target))
        #expect(commands.map(\.title) == ["Refresh", "Dual"])
        #expect(commands.map(\.path) == ["View", "View › Layout"])
        #expect(commands.first?.shortcut == "⌘R")
        #expect(commands.last?.shortcut == "")
    }

    @Test func whatTheMenuWouldGrayOutIsNotOffered() {
        target.enabled = false
        #expect(MenuCommand.collect(from: menu(target: target)).isEmpty)
    }

    @Test func skippedActionsAreLeftOut() {
        #expect(MenuCommand.collect(from: menu(target: target), skipping: [#selector(Target.go(_:))]).isEmpty)
    }

    @Test func runningFiresTheMenuItem() throws {
        let main = menu(target: target)
        let command = try #require(MenuCommand.collect(from: main).first)
        #expect(command.run())
        #expect(target.fired == ["Refresh"])
    }

    @Test func aCommandDisabledSinceTheListWasMadeDoesNotRun() throws {
        let main = menu(target: target)
        let command = try #require(MenuCommand.collect(from: main).first)
        target.enabled = false
        #expect(!command.run())
        #expect(target.fired.isEmpty)
    }

    @Test func aCommandRemovedSinceTheListWasMadeDoesNotRun() throws {
        let main = menu(target: target)
        let command = try #require(MenuCommand.collect(from: main).first)
        command.item.menu?.removeItem(command.item)
        #expect(!command.run())
    }

    @Test func theRealMenusAllHaveTitlesAndUniqueIDs() {
        let main = MainMenu.build()
        var ids: [String] = []
        func walk(_ menu: NSMenu, _ trail: String) {
            for item in menu.items where !item.isSeparatorItem {
                if let sub = item.submenu { walk(sub, trail + item.title + "›") } else if item.action != nil {
                    #expect(!item.title.isEmpty)
                    ids.append(trail + item.title)
                }
            }
        }
        walk(main, "")
        #expect(ids.count > 40)
    }
}

@MainActor @Suite struct QuickLauncherModelTests {
    private let target = Target()

    /// NSMenu validates nothing until the application object exists
    init() { _ = NSApplication.shared }

    private func model(_ target: Target, history: MemoryHistory = MemoryHistory()) -> QuickLauncherModel {
        let main = NSMenu()
        let edit = main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Edit")
        edit.submenu = menu
        menu.addItem(withTitle: "Copy Path", action: #selector(Target.go(_:)), keyEquivalent: "").target = target
        menu.addItem(withTitle: "Refresh", action: #selector(Target.go(_:)), keyEquivalent: "").target = target
        let locations = QuickLocationsModel(fixed: [QuickLocation(kind: .bookmark, title: "Copies", path: "/copies")],
                                            home: URL(fileURLWithPath: "/Users/me"))
        return QuickLauncherModel(commands: MenuCommand.collect(from: main), locations: locations, history: history)
    }

    @Test func commandsAndLocationsShareTheList() {
        let rows = model(target).rows("cop")
        #expect(Set(rows.map(\.title)) == ["Copy Path", "Copies"])
        #expect(rows.first { $0.title == "Copy Path" }?.subtitle == "Edit")
        #expect(rows.first { $0.title == "Copies" }?.subtitle == "/copies")
    }

    @Test func aChevronLeavesOnlyCommands() {
        #expect(model(target).rows(">cop").map(\.title) == ["Copy Path"])
        #expect(model(target).rows(">").map(\.title) == ["Copy Path", "Refresh"])
    }

    @Test func aPathGoesToThatPath() {
        let rows = model(target).rows("~/x")
        #expect(rows.first?.id == "/Users/me/x")
    }

    @Test func aChevronPathIsACommandSearch() {
        #expect(model(target).rows(">/x").isEmpty)
    }

    @Test func aRowLeadsBackToItsCommand() throws {
        let model = model(target)
        let row = try #require(model.rows(">refresh").first)
        #expect(model.command(forRow: row.id)?.title == "Refresh")
        #expect(model.command(forRow: "/copies") == nil)
    }

    @Test func aRunIsRememberedAndComesFirstNextTime() throws {
        let history = MemoryHistory()
        let model = model(target, history: history)
        let row = try #require(model.rows(">refresh").first)
        #expect(model.run(try #require(model.command(forRow: row.id))))
        #expect(target.fired == ["Refresh"])
        #expect(model.rows("").first?.title == "Refresh")
    }

    @Test func aRefusedRunIsNotRemembered() throws {
        let history = MemoryHistory()
        let model = model(target, history: history)
        let row = try #require(model.rows(">refresh").first)
        target.enabled = false
        #expect(!model.run(try #require(model.command(forRow: row.id))))
        #expect(history.ids.isEmpty)
    }

    @Test func theMenuAndShortcutAreRegistered() {
        NSApplication.shared.mainMenu = MainMenu.build()
        #expect(MainMenu.uiTestMenuItem(for: #selector(MainWindowController.showQuickLauncher(_:)))?.ownerTitle == L10n.t("menu.go"))
        #expect(KeyBindings.entry("quickLauncher")?.defaultKey == "p")
    }
}
