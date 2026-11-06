import AppKit
import Frecency
import QuickLauncher
import QuickLocations

/// The launcher's command history, app-wide
@MainActor
enum QuickLauncherHost {
    static var store: any CommandHistoryStoring = CommandHistoryStore(directory: AppDelegate.supportDirectory)
}

/// A menu command that can run now. The launcher offers what the menus offer, so a new menu item needs no second list,
/// and what the menus would gray out at this moment is not on offer.
@MainActor
struct MenuCommand {
    let id: String
    let title: String
    /// Menus leading to it: "View › Layout"
    let path: String
    let shortcut: String
    let item: NSMenuItem

    /// Ask with the main window key: that is the responder chain the commands will run in.
    static func collect(from main: NSMenu, skipping skipped: [Selector] = []) -> [MenuCommand] {
        var found: [MenuCommand] = []
        func walk(_ menu: NSMenu, trail: [String]) {
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            for item in menu.items where !item.isSeparatorItem && !item.isHidden {
                if let submenu = item.submenu {
                    walk(submenu, trail: trail + [item.title])
                } else if let action = item.action, item.isEnabled, !skipped.contains(action) {
                    let path = trail.joined(separator: " › ")
                    found.append(MenuCommand(id: "\(path) › \(item.title)", title: item.title, path: path,
                                             shortcut: KeyBindings.display(key: item.keyEquivalent, mods: item.keyEquivalentModifierMask),
                                             item: item))
                }
            }
        }
        for top in main.items {
            guard let submenu = top.submenu else { continue }
            walk(submenu, trail: [top.title])
        }
        return found
    }

    /// False when the command has gone or was disabled since the list was made
    @discardableResult
    func run() -> Bool {
        guard let menu = item.menu else { return false }
        let index = menu.index(of: item)
        guard index >= 0 else { return false }
        menu.update()
        guard item.isEnabled else { return false }
        menu.performActionForItem(at: index)
        return true
    }
}

/// What the launcher shows for a query
@MainActor
final class QuickLauncherModel {
    private static let commandPrefix = "command:"

    private let commands: [MenuCommand]
    private let locations: QuickLocationsModel
    private let history: any CommandHistoryStoring

    init(commands: [MenuCommand], locations: QuickLocationsModel, history: any CommandHistoryStoring) {
        self.commands = commands
        self.locations = locations
        self.history = history
    }

    func setRecents(_ recents: [QuickLocation]) { locations.setRecents(recents) }

    func rows(_ raw: String) -> [QuickRow] {
        let query = LauncherQuery(raw)
        var places = query.commandsOnly ? [] : locations.matches(raw)
        let byID = Dictionary(commands.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let typed = places.first?.kind == .typed ? places.removeFirst() : nil
        let entries = commands.map { LauncherEntry(id: Self.commandPrefix + $0.id, kind: .command, title: $0.title, detail: $0.path) }
            + places.map { LauncherEntry(id: $0.id, kind: .location, title: $0.title, detail: $0.path) }
        let recent = history.recent().map { Self.commandPrefix + $0 }
        let ranked = LauncherRanking.rank(entries, query: query, recent: recent) { query, title, detail in
            SearchRanking.matchScore(query: query, name: title, path: detail)
        }
        let rows = ranked.compactMap { entry -> QuickRow? in
            switch entry.kind {
            case .command:
                let id = String(entry.id.dropFirst(Self.commandPrefix.count))
                guard let command = byID[id] else { return nil }
                return QuickRow(id: entry.id, title: command.title, subtitle: command.path, symbol: "command", trailing: command.shortcut)
            case .location:
                return places.first { $0.id == entry.id }.map(QuickLocationsModel.row)
            }
        }
        return (typed.map { [QuickLocationsModel.row($0)] } ?? []) + rows
    }

    func command(forRow id: String) -> MenuCommand? {
        guard id.hasPrefix(Self.commandPrefix) else { return nil }
        let wanted = id.dropFirst(Self.commandPrefix.count)
        return commands.first { $0.id == wanted }
    }

    /// Runs a chosen command and remembers it. A history that cannot be saved must not stop the command.
    func run(_ command: MenuCommand) -> Bool {
        guard command.run() else { return false }
        do {
            try history.record(command.id)
        } catch let error as LauncherError {
            ProblemAlert.show(error)
        } catch {
            assertionFailure("record only throws LauncherError: \(error)")
        }
        return true
    }
}

extension MainWindowController {
    @objc func showQuickLauncher(_ sender: Any?) {
        guard let menu = NSApp.mainMenu else { return }
        // Collected before the panel takes the keyboard, while the responder chain is still the window's
        let commands = MenuCommand.collect(from: menu, skipping: [
            #selector(showQuickLauncher(_:)), #selector(showQuickLocations(_:)), #selector(showBookmarkPanel(_:)),
        ])
        let locations = QuickLocationsModel(fixed: sidebar.model.quickLocations(bookmarksOnly: false))
        let model = QuickLauncherModel(commands: commands, locations: locations, history: QuickLauncherHost.store)
        let panel = QuickPanelController.shared
        let store = coordinator.frecencyStore
        let recents = Task {
            let folders = await QuickLocationsModel.recentFolders(from: store)
            guard !Task.isCancelled else { return }
            model.setRecents(folders)
            panel.refresh()
        }
        panel.show(QuickPanelContent(placeholder: L10n.t("quick.launcher.placeholder"), rows: model.rows, choose: { [weak self] row, modifiers in
            guard let command = model.command(forRow: row.id) else {
                self?.go(toPath: row.id, newTab: modifiers.contains(.command))
                return
            }
            // Next turn: the panel has just given the keyboard back, and the command must see the window as key
            DispatchQueue.main.async {
                if !model.run(command) { Toast.show(L10n.f("quick.commandGone", command.title), in: self?.window) }
            }
        }, onClose: { recents.cancel() }), over: window)
        ProblemAlert.show(QuickLauncherHost.store.takeProblem())
    }
}
