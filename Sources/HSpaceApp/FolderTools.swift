import AppKit
import BatchRename
import HSpaceContracts

/// Merge and flatten. The moves are ordinary kernel moves: Transfer owns the conflict panel, its merge rules
/// (file over file replaces, folder into folder recurses, a file and a folder are both kept), progress and cancel.
/// This layer plans, asks first, and clears away the folders that really ended up empty.
@MainActor
final class FolderTools {
    private let coordinator: FileOpsCoordinator
    /// Where emptied folders go. Replaced in tests, which must not fill the real Trash.
    var discard: ([URL]) -> Void

    init(coordinator: FileOpsCoordinator) {
        self.coordinator = coordinator
        discard = { [weak coordinator] in coordinator?.moveToTrash($0) }
    }

    /// Reads a whole tree, so it stays off the main thread.
    nonisolated static func plan(_ make: @escaping @Sendable () throws -> FolderPlan) async throws -> FolderPlan {
        try await Task.detached(operation: make).value
    }

    /// Runs a plan. Returns false when the move did not finish, and then nothing is discarded:
    /// the plan's folders still hold what was not moved.
    @discardableResult
    func run(_ plan: FolderPlan) async -> Bool {
        var finished = true
        if !plan.moves.isEmpty {
            finished = await withCheckedContinuation { done in
                coordinator.transfer(urls: plan.moves, into: plan.target, move: true) { done.resume(returning: $0) }
            }
        }
        guard finished else { return false }
        do {
            let empty = try await Task.detached { try plan.emptied.filter(FolderPlanner.isEmptied) }.value
            if !empty.isEmpty { discard(empty) }
        } catch {
            ToolUI.showError(error.localizedDescription, in: coordinator.grid?.view.window)
        }
        return true
    }
}

extension MainWindowController {
    /// Real folders in the selection. Packages and links are items, not places to merge. nil inside the Trash.
    var selectedFolders: [FileItem]? {
        guard renamableSelection != nil else { return nil }
        return grid.activePane.toolSelection.filter { $0.isDirectory && !$0.isPackage && !$0.isSymlink }
    }

    @objc func showMergeFolders(_ sender: Any?) {
        guard let folders = selectedFolders, folders.count > 1, let window else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = L10n.f("merge.title", folders.count)
        alert.informativeText = L10n.t("merge.body")
        let target = ToolUI.popup(folders.map(\.name), label: L10n.t("merge.target"), target: nil, action: nil)
        target.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = target
        alert.addButton(withTitle: L10n.t("merge.confirm"))
        alert.addButton(withTitle: L10n.t("common.cancel"))
        let urls = folders.map(\.url)
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn, let self else { return }
                let chosen = urls[target.indexOfSelectedItem]
                self.runFolderTool { try FolderPlanner.mergePlan(folders: urls, into: chosen) }
            }
        }
    }

    @objc func showFlattenFolder(_ sender: Any?) {
        guard let folders = selectedFolders, folders.count == 1, let window else { NSSound.beep(); return }
        let folder = folders[0].url
        Task {
            do {
                let plan = try await FolderTools.plan { try FolderPlanner.flattenPlan(folder: folder) }
                let alert = NSAlert()
                alert.messageText = L10n.f("flatten.title", folder.lastPathComponent)
                alert.informativeText = L10n.f("flatten.body", plan.moves.count, plan.emptied.count)
                alert.addButton(withTitle: L10n.t("flatten.confirm"))
                alert.addButton(withTitle: L10n.t("common.cancel"))
                guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
                await FolderTools(coordinator: coordinator).run(plan)
            } catch {
                ToolUI.showError(error.localizedDescription, in: window)
            }
        }
    }

    private func runFolderTool(_ make: @escaping @Sendable () throws -> FolderPlan) {
        Task {
            do {
                let plan = try await FolderTools.plan(make)
                await FolderTools(coordinator: coordinator).run(plan)
            } catch {
                ToolUI.showError(error.localizedDescription, in: window)
            }
        }
    }
}
