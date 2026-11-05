import AppKit
import ArchiveEngine
import ArchivePasswords
import HSpaceContracts

enum ArchivePasswordDecision: Equatable {
    case notNeeded
    case password(String)
    case cancelled
}

/// Finds the password of an encrypted archive: saved passwords first, then the user.
/// Passwords stay in memory for the operation at hand, and go to disk only through the Keychain, when the user asks.
@MainActor
final class ArchivePasswordResolver {
    /// nil = the user cancelled. `retry` says the previous answer was wrong.
    typealias Ask = @MainActor (_ archive: URL, _ retry: Bool) async -> (password: String, remember: Bool)?

    private let list: PasswordList
    private let ask: Ask
    private let engine = ArchiveEngineNode()

    init(list: PasswordList, ask: @escaping Ask) {
        self.list = list
        self.ask = ask
    }

    func resolve(_ archive: URL) async throws -> ArchivePasswordDecision {
        guard try await ArchiveEngineNode.isEncrypted(archive) else { return .notNeeded }
        if let saved = try await firstSavedPassword(for: archive) { return .password(saved) }

        var retry = false
        while let answer = await ask(archive, retry) {
            if try await unlocks(answer.password, archive) {
                if answer.remember { remember(answer.password, for: archive) }
                return .password(answer.password)
            }
            retry = true
        }
        return .cancelled
    }

    private func firstSavedPassword(for archive: URL) async throws -> String? {
        let saved: [SavedPassword]
        do {
            saved = try list.load()
        } catch {
            // Asking still works without the list
            ProblemAlert.show(error as? any ClassifiedError)
            return nil
        }
        for entry in saved where try await unlocks(entry.password, archive) {
            return entry.password
        }
        return nil
    }

    /// A password that tar could not be given is simply not the right one
    private func unlocks(_ password: String, _ archive: URL) async throws -> Bool {
        do {
            return try await engine.password(password, unlocks: archive)
        } catch let error as ArchiveError where error.errorClass == .logic {
            return false
        }
    }

    /// Named after the archive, which helps to recognise an entry later. Failing to save does not stop the extraction.
    private func remember(_ password: String, for archive: URL) {
        do {
            try list.add(label: archive.lastPathComponent, password: password)
        } catch {
            ProblemAlert.show(error as? any ClassifiedError)
        }
    }
}

/// The password dialogs. A password field never shows its text, and is not kept after the dialog.
@MainActor
enum ArchivePasswordUI {
    private static func secureField(_ placeholderKey: String) -> NSSecureTextField {
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = L10n.t(placeholderKey)
        field.setAccessibilityLabel(L10n.t(placeholderKey))
        return field
    }

    private static func accessory(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 280, height: CGFloat(views.count) * 32)
        for view in views {
            view.widthAnchor.constraint(equalToConstant: 280).isActive = true
        }
        return stack
    }

    private static func run(_ alert: NSAlert, firstResponder: NSView?) async -> NSApplication.ModalResponse {
        alert.window.initialFirstResponder = firstResponder
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return alert.runModal() }
        return await withCheckedContinuation { done in
            alert.beginSheetModal(for: window) { done.resume(returning: $0) }
        }
    }

    /// Asks for the password of an archive
    static func ask(archive: URL, retry: Bool) async -> (password: String, remember: Bool)? {
        let alert = NSAlert()
        alert.messageText = L10n.f("archive.password.title", archive.lastPathComponent)
        alert.informativeText = L10n.t(retry ? "archive.password.wrong" : "archive.password.message")
        alert.addButton(withTitle: L10n.t("archive.password.unlock"))
        alert.addButton(withTitle: L10n.t("common.cancel"))
        let field = secureField("archive.password.field")
        let remember = NSButton(checkboxWithTitle: L10n.t("archive.password.remember"), target: nil, action: nil)
        alert.accessoryView = accessory([field, remember])
        guard await run(alert, firstResponder: field) == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return nil }
        return (field.stringValue, remember.state == .on)
    }

    /// Asks for a new password, twice, until both match. Says what the encryption does and does not cover.
    static func askForNewPassword(message: String? = nil) async -> (password: String, remember: Bool)? {
        let alert = NSAlert()
        alert.messageText = L10n.t("archive.newPassword.title")
        alert.informativeText = message ?? L10n.t("archive.newPassword.message")
        alert.addButton(withTitle: L10n.t("menu.compressWithPassword.action"))
        alert.addButton(withTitle: L10n.t("common.cancel"))
        let first = secureField("archive.password.field")
        let second = secureField("archive.newPassword.confirm")
        first.nextKeyView = second
        let remember = NSButton(checkboxWithTitle: L10n.t("archive.password.remember"), target: nil, action: nil)
        alert.accessoryView = accessory([first, second, remember])
        guard await run(alert, firstResponder: first) == .alertFirstButtonReturn else { return nil }
        guard !first.stringValue.isEmpty, first.stringValue == second.stringValue else {
            return await askForNewPassword(message: L10n.t("archive.newPassword.mismatch"))
        }
        return (first.stringValue, remember.state == .on)
    }

    /// A label and a password for the saved list
    static func askForSavedPassword(in window: NSWindow) async -> (label: String, password: String)? {
        let alert = NSAlert()
        alert.messageText = L10n.t("archive.passwords.add.title")
        alert.informativeText = L10n.t("archive.passwords.note")
        alert.addButton(withTitle: L10n.t("archive.passwords.add"))
        alert.addButton(withTitle: L10n.t("common.cancel"))
        let label = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        label.placeholderString = L10n.t("archive.passwords.label")
        label.setAccessibilityLabel(L10n.t("archive.passwords.label"))
        let field = secureField("archive.password.field")
        label.nextKeyView = field
        alert.accessoryView = accessory([label, field])
        alert.window.initialFirstResponder = label
        let response = await withCheckedContinuation { (done: CheckedContinuation<NSApplication.ModalResponse, Never>) in
            alert.beginSheetModal(for: window) { done.resume(returning: $0) }
        }
        guard response == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return nil }
        let name = label.stringValue.trimmingCharacters(in: .whitespaces)
        return (name.isEmpty ? L10n.t("archive.passwords.unnamed") : name, field.stringValue)
    }
}

/// The saved passwords, as labels. Opening it is what reads the Keychain, so settings alone never raise a Keychain prompt.
@MainActor
final class ArchivePasswordsSheetController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static var live: ArchivePasswordsSheetController?

    static func present(list: PasswordList, in host: NSWindow) {
        guard live == nil, host.attachedSheet == nil else { return }
        let sheet = ArchivePasswordsSheetController(list: list, host: host)
        live = sheet
        host.beginSheet(sheet.panel) { _ in }
        sheet.reload()
    }

    private let list: PasswordList
    private let host: NSWindow
    private let panel = ToolUI.panel(width: 420, height: 320)
    private var entries: [SavedPassword] = []
    private var table: NSTableView!
    private lazy var removeButton = ToolUI.button(L10n.t("archive.passwords.remove"), target: self, action: #selector(removeSelected))

    init(list: PasswordList, host: NSWindow) {
        self.list = list
        self.host = host
        super.init()
        let (scroll, table) = ToolUI.table(columns: [("label", L10n.t("archive.passwords.label"), 360)], source: self, height: 180)
        self.table = table
        removeButton.isEnabled = false
        let note = NSTextField(wrappingLabelWithString: L10n.t("archive.passwords.note"))
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        ToolUI.fill(panel, with: [
            ToolUI.title(L10n.t("archive.passwords.title")), note, scroll,
            ToolUI.buttonRow([ToolUI.button(L10n.t("archive.passwords.add"), target: self, action: #selector(addPassword)),
                              removeButton, ToolUI.button(L10n.t("common.close"), target: self, action: #selector(close))]),
        ])
    }

    private func reload() {
        do {
            entries = try list.load()
        } catch {
            entries = []
            ToolUI.showError((error as? any ClassifiedError)?.localizedDescription ?? error.localizedDescription, in: panel)
        }
        table.reloadData()
        removeButton.isEnabled = false
    }

    @objc private func addPassword() {
        Task {
            guard let answer = await ArchivePasswordUI.askForSavedPassword(in: panel) else { return }
            do {
                try list.add(label: answer.label, password: answer.password)
            } catch {
                ToolUI.showError((error as? any ClassifiedError)?.localizedDescription ?? error.localizedDescription, in: panel)
            }
            reload()
        }
    }

    @objc private func removeSelected() {
        guard entries.indices.contains(table.selectedRow) else { return }
        let entry = entries[table.selectedRow]
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.f("archive.passwords.remove.title", entry.label)
        alert.informativeText = L10n.t("archive.passwords.remove.message")
        alert.addButton(withTitle: L10n.t("archive.passwords.remove"))
        alert.addButton(withTitle: L10n.t("common.cancel"))
        alert.beginSheetModal(for: panel) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn, let self else { return }
                do {
                    try self.list.remove(id: entry.id)
                } catch {
                    ToolUI.showError((error as? any ClassifiedError)?.localizedDescription ?? error.localizedDescription, in: self.panel)
                }
                self.reload()
            }
        }
    }

    @objc private func close() {
        host.endSheet(panel)
        panel.orderOut(nil)
        Self.live = nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        ToolUI.cell(in: tableView, text: entries[row].label)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = table.selectedRow >= 0
    }
}

extension MainWindowController {
    @objc func showCompressWithPassword(_ sender: Any?) {
        let urls = grid.activePane.toolSelection.map(\.url)
        guard !urls.isEmpty else { NSSound.beep(); return }
        Task {
            guard let answer = await ArchivePasswordUI.askForNewPassword() else { return }
            if answer.remember {
                do {
                    let name = urls.count == 1 ? urls[0].lastPathComponent : L10n.t("archive.defaultName")
                    try coordinator.archivePasswordList.add(label: name, password: answer.password)
                } catch {
                    ProblemAlert.show(error as? any ClassifiedError)
                }
            }
            coordinator.compress(urls, password: answer.password)
        }
    }
}
