import AppKit
import FileMetadata

/// "Always open this kind with…". A system-wide setting, so it asks first and can be undone.
extension FileOpsCoordinator {
    func confirmDefaultApp(typeID: String, kindName: String, app: URL) {
        guard let window = grid?.view.window, window.attachedSheet == nil else { return }
        let appName = FileManager.default.displayName(atPath: app.path)
        let alert = NSAlert()
        alert.messageText = L10n.f("defaultApp.confirmTitle", kindName, appName)
        alert.informativeText = L10n.t("defaultApp.confirmBody")
        alert.addButton(withTitle: L10n.t("common.cancel"))
        alert.addButton(withTitle: L10n.t("defaultApp.confirm"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            MainActor.assumeIsolated {
                self?.setDefaultApp(typeID: typeID, kindName: kindName, app: app) { _ in }
            }
        }
    }

    /// `done` gets the change, or nil when it failed, which a toast has reported by then.
    func setDefaultApp(typeID: String, kindName: String, app: URL,
                       done: @escaping @MainActor (DefaultAppChange?) -> Void) {
        changeDefaultApp(typeID: typeID, kindName: kindName, app: app) { [weak self] change in
            // Without an earlier app there is nothing to go back to, so no undo is offered
            if let change, let previous = change.previous {
                self?.registerDefaultAppStep(typeID: typeID, kindName: kindName, to: previous, back: app)
            }
            done(change)
        }
    }

    private func changeDefaultApp(typeID: String, kindName: String, app: URL,
                                  done: @escaping @MainActor (DefaultAppChange?) -> Void) {
        let window = grid?.view.window
        let apps = DefaultApps(registry: defaultAppRegistry)
        Task { @MainActor in
            do {
                let change = try await apps.change(typeID: typeID, to: app)
                Toast.show(L10n.f("toast.defaultApp", kindName, FileManager.default.displayName(atPath: app.path)), in: window)
                done(change)
            } catch {
                Toast.show(error.localizedDescription, in: window)
                done(nil)
            }
        }
    }

    /// Registers one undo or redo step. Each step registers its opposite at once, while UndoManager is undoing,
    /// or it would land on the wrong stack.
    private func registerDefaultAppStep(typeID: String, kindName: String, to app: URL, back: URL) {
        undoManager.registerUndo(withTarget: self) { coord in
            MainActor.assumeIsolated {
                coord.registerDefaultAppStep(typeID: typeID, kindName: kindName, to: back, back: app)
                coord.changeDefaultApp(typeID: typeID, kindName: kindName, app: app) { _ in }
            }
        }
        undoManager.setActionName(L10n.t("undo.defaultApp"))
    }
}
