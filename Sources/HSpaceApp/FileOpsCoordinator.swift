import AppKit
import HSpaceKernel
import HSpaceContracts
import ArchiveEngine
import ArchivePasswords
import Frecency
import TrashLedger
import FileMetadata

/// Reveals the result of an operation (after creating an item: select it and enter rename if needed); implemented by the list and icon views (column view passes nil)
@MainActor
protocol FileRevealTarget: AnyObject {
    func prepareReveal(_ url: URL, rename: Bool)
    /// Takes and clears the pending reveal target. Used to "relocate" it on a view-mode switch: if the switch happens mid-read, the pending target is still on the old view,
    /// and without relocation it is lost for good and left in the old view as a time bomb that later "ghost-selects" and steals focus.
    func takePendingReveal() -> (url: URL, rename: Bool)?
}

/// What a restore really did.
struct RestoreOutcome: Sendable {
    var restored = 0
    /// Where restored items are now, without those that joined an existing item (TrashRestoreStep.restored)
    var landed: [URL] = []
}

/// Shared between `restore` and its redo closure, which is registered before the outcome is known.
@MainActor
private final class RestoreRecord {
    var value = RestoreOutcome()
}

/// UI → kernel bridge (one per window): translates user intent into an OperationSpec for OperationKernel,
/// executed by pod nodes (BG-1: no write-type file APIs in this layer). Handles the clipboard, undo registration and post-operation pane refresh.
@MainActor
final class FileOpsCoordinator {
    let kernel: OperationKernel
    private(set) weak var grid: PaneGridController?
    /// This window's undo stack (wired to ⌘Z through MainWindowController.windowWillReturnUndoManager)
    let undoManager = UndoManager()

    /// URLs in the cut state: cut rows are dimmed; cleared after paste or copy
    private var cutURLs: Set<URL> = []

    /// Usage learning (M28): carrier of the app-wide open/enter bookkeeping (AppDelegate injects the same instance; nil = no learning).
    var frecencyStore: FrecencyStore?

    /// Put Back ledger (AppDelegate injects the same instance; nil = no bookkeeping → Put Back is always unavailable)
    var trashLedger: TrashLedger?

    /// Target of the tag menus (menu items hold their target weakly, so it lives here)
    private(set) lazy var metadataActions = MetadataActions(coordinator: self)
    /// Keeps Finder's Get Info in step with comments changed here
    var finderComments: any FinderCommentPushing = OsascriptFinderComments()
    /// Where "always open with" lands
    var defaultAppRegistry: any DefaultAppRegistry = SystemDefaultApps()
    /// Saved archive passwords, in the Keychain
    var archivePasswordList = PasswordList(store: KeychainSecretStore())
    /// Finds the password of an encrypted archive
    lazy var archivePasswords = ArchivePasswordResolver(list: archivePasswordList) { archive, retry in
        await ArchivePasswordUI.ask(archive: archive, retry: retry)
    }

    /// Records one access (file opened/folder entered) so Spotlight-style search can rank by usage. Fire-and-forget async commit to the actor.
    func recordAccess(_ url: URL) {
        guard let store = frecencyStore else { return }
        Task { await store.record(url) }
    }

    init(kernel: OperationKernel, grid: PaneGridController) {
        self.kernel = kernel
        self.grid = grid
    }

    // MARK: Clipboard state query (the list dims cut items from this)

    func isCut(_ url: URL) -> Bool { cutURLs.contains(url) }

    // MARK: Copy / Cut / Paste / Copy Path

    func copy(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        writeToPasteboard(urls)
        cutURLs = []
        redrawLists()
        Toast.show(String(format: L10n.t("toast.copied"), urls.count), in: grid?.view.window)
    }

    func cut(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        writeToPasteboard(urls)
        cutURLs = Set(urls)
        redrawLists()
        Toast.show(String(format: L10n.t("toast.cutN"), urls.count), in: grid?.view.window)
    }

    func paste(into directory: URL, revealIn list: FileRevealTarget? = nil) {
        guard !Self.isTrashDestination(directory) else {
            Toast.show(L10n.t("toast.notIntoTrash"), in: grid?.view.window)
            return
        }
        let urls = readPasteboardURLs()
        // With no files on the clipboard, paste the **content** as a new file (text/image/PDF/RTF).
        // The old version just beeped, so anything copied from a browser or a screenshot had nowhere to land.
        guard !urls.isEmpty else { pasteContentAsNewFile(into: directory, revealIn: list); return }
        // Cut state and the pasted items are exactly the cut set → move; otherwise copy
        let isMove = !cutURLs.isEmpty && urls.allSatisfy { cutURLs.contains($0) }
        // M27-B: same-directory copy-paste no longer silently degrades to "duplicate". A normal copy triggers a self-source conflict,
        // showing the panel for Replace/Skip/Keep Both/Rename/Cancel (protected by the engine's self-source safety rule; the source is never deleted).
        let spec = OperationSpec(kind: isMove ? .move : .copy, sources: urls, destination: directory)
        run(spec) { [weak self] _ in
            if isMove { self?.cutURLs = []; self?.redrawLists() }
        }
    }

    /// Clipboard content → new file. Type priority: PNG → TIFF → PDF → RTF → plain text.
    /// Content is not written in this layer (BG-1): it goes to the kernel with the `newFile` Command and LocalOps writes it.
    /// The pasteboard is injectable (self-tests use a private board and never touch the user's real clipboard).
    func pasteContentAsNewFile(into directory: URL, revealIn list: FileRevealTarget? = nil,
                               from pasteboard: NSPasteboard = .general) {
        guard let payload = Self.contentPayload(from: pasteboard) else {
            NSSound.beep()
            Toast.show(L10n.t("toast.pasteNothing"), in: grid?.view.window)
            return
        }
        run(OperationSpec(kind: .newFile, sources: [], destination: directory,
                          newName: payload.name, contents: payload.data)) { [weak self] receipt in
            guard let self, let url = receipt?.createdURLs.first else { return }
            // Select it in the list once it lands. rename: false, because the name is derived from the content type
            // and popping a rename field would interrupt the "paste and use" flow
            list?.prepareReveal(url, rename: false)
            Toast.show(L10n.f("toast.pastedAsFile", url.lastPathComponent),
                       in: self.grid?.view.window)
        }
    }

    /// Reads "content + suggested file name" from the clipboard. Pure function (pasteboard as a parameter), deterministically unit-testable.
    nonisolated static func contentPayload(from pb: NSPasteboard) -> (name: String, data: Data)? {
        // Order is priority: images before text, otherwise an image copied from a browser degrades to a chunk of HTML text
        let candidates: [(NSPasteboard.PasteboardType, String)] = [
            (.png, "png"), (.tiff, "tiff"), (.pdf, "pdf"), (.rtf, "rtf"),
        ]
        for (type, ext) in candidates {
            if let d = pb.data(forType: type), !d.isEmpty {
                return (L10n.t("paste.imageBaseName") + "." + ext, d)
            }
        }
        if let s = pb.string(forType: .string), !s.isEmpty {
            return (L10n.t("paste.textBaseName") + ".txt", Data(s.utf8))
        }
        return nil
    }

    /// Copies paths. The pasteboard is injectable: the default is the system clipboard (product behaviour); self-tests inject a private board,
    /// which neither pollutes the user's real clipboard nor fails spuriously when another process rewrites it mid-test (this really happened).
    func copyPaths(_ urls: [URL], to pasteboard: NSPasteboard = .general) {
        guard !urls.isEmpty else { return }
        let pb = pasteboard
        pb.clearContents()
        pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        Toast.show(urls.count == 1 ? L10n.t("toast.copiedPath")
                   : String(format: L10n.t("toast.copiedPaths"), urls.count),
                   in: grid?.view.window)
    }

    // MARK: Empty Trash / Put Back (v0.19.19)

    /// Empty Trash: **irreversible**. Reads the Trash contents (read-only, allowed by BG-1) → confirms → kernel `.delete`.
    /// The fence root is that Trash itself; the node rejects anything outside the fence.
    func emptyTrash(at trash: URL, in window: NSWindow?) {
        guard let window = window ?? grid?.view.window, window.attachedSheet == nil else { return }
        // options: [] reads everything: the Trash may hold dotfiles, and a display filter would miss them, making "Empty" a half-truth
        let victims = (try? FileManager.default.contentsOfDirectory(
            at: trash, includingPropertiesForKeys: nil, options: [])) ?? []
        guard !victims.isEmpty else {
            Toast.show(L10n.t("toast.trashAlreadyEmpty"), in: window)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L10n.f("alert.emptyTrash.title", victims.count)
        alert.informativeText = L10n.t("alert.emptyTrash.body")
        // Return must never trigger emptying: an irreversible operation must not run from just pressing Return.
        // This is done by **putting Cancel in the first button slot**, not `alert.window.defaultButtonCell = cancel.cell`.
        // That is an old draw-time API and doesn't move "\r" from Empty to Cancel; when the app is inactive
        // or the sheet isn't the key window, AppKit's sync never happens and the default stays on Empty
        // (reproduced reliably across three real-gate runs). It wasn't an unreadable assertion: the safety invariant really didn't hold.
        //
        // Actual key bindings after the swap (measured, not guessed): AppKit recognizes Cancel **by title** and gives it
        // Escape, a rule that outranks "first button gets Return". So Return binds to no button and Esc cancels.
        // Kept this way on purpose: a button binds only one key, Esc is the universal dialog-cancel gesture,
        // and Return should do nothing in a destructive dialog anyway.
        alert.addButton(withTitle: L10n.t("common.cancel"))
        alert.addButton(withTitle: L10n.t("alert.emptyTrash.confirm"))
        alert.buttons[1].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            self?.performEmptyTrash(at: trash, victims: victims)
        }
    }

    /// Permanent deletion is entered only from a confirmed window action.
    private func performEmptyTrash(at trash: URL, victims: [URL]) {
        guard !victims.isEmpty else { return }
        run(OperationSpec(kind: .delete, sources: victims, destination: trash)) { [weak self] receipt in
            guard let self, let receipt else { return }
            // Void the ledger entries of what was really erased; failed items are still in the Trash
            if let led = self.trashLedger {
                Task {
                    await led.forgetErased(victims, receipt: receipt)
                    ProblemAlert.show(await led.takeProblem())
                }
            }
            if receipt.failures.isEmpty {
                Toast.show(L10n.f("toast.trashEmptied", receipt.filesDone), in: self.grid?.view.window)
            } else {
                Toast.show(L10n.f("toast.trashEmptiedPartial", receipt.filesDone,
                                  receipt.failures.count, receipt.failures[0].message),
                           in: self.grid?.view.window)
            }
        }
    }

    /// Put Back: works only for items **recorded in the ledger** (= deleted by HSpace itself).
    /// Items deleted by other apps have no record, so the menu item is honestly grayed out rather than pretending it can restore them.
    func putBack(_ urls: [URL]) {
        guard !urls.isEmpty, let led = trashLedger else { NSSound.beep(); return }
        Task { @MainActor in
            let map = await led.origins(of: urls)
            let known = urls.compactMap { u in map[u].map { (trashed: u, original: $0) } }
            guard !known.isEmpty else {
                Toast.show(L10n.t("toast.putBackUnknown"), in: self.grid?.view.window)
                return
            }
            // Reuses the existing "move back + rename to the original name if needed" chain (the same one Trash undo uses)
            self.restore(known.map { TrashedItem(original: $0.original, trashed: $0.trashed) }) { outcome in
                // Items that stayed in the Trash keep their record; the progress window reports why they failed
                guard outcome.restored > 0 else { return }
                Toast.show(L10n.f("toast.putBackN", outcome.restored), in: self.grid?.view.window)
            }
        }
    }

    // MARK: Kernel operations

    func moveToTrash(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        // A case that appeared once the Trash became browsable: trashing an item **already in ~/.Trash**.
        // Measured: `fm.trashItem` is a safe no-op here (returns the same path, the file stays, no error),
        // so there is no data risk, but it would toast a false "moved N items to Trash". Refuse honestly instead.
        // The real way out is permanent deletion, which needs a new kernel kind + new pod node (irreversible, the owner's call).
        // The quantifier is `contains`, not `allSatisfy`: with a mixed selection (some in the Trash, some not) allSatisfy would
        // let it through, then the toast reports an inflated items.count and ⌘Z gets an inconsistent undo set.
        // Refusing the whole batch is predictable; narrowing the selection once lets the user continue.
        if urls.contains(where: { TrashLocation.isInsideTrash($0) }) {
            Toast.show(L10n.t("toast.alreadyInTrash"), in: grid?.view.window)
            return
        }
        run(OperationSpec(kind: .trash, sources: urls)) { [weak self] receipt in
            guard let self, let receipt else { return }
            let items = receipt.trashedItems
            // What actually landed must be undoable, even if the whole run was marked .failed because of other items
            if !items.isEmpty {
                self.registerRestoreUndo(items)
                // Record in the ledger: cross-session Put Back depends on it (UndoManager lives only in this window for this session)
                let pairs = items.map { (original: $0.original, trashed: $0.trashed) }
                if let led = self.trashLedger {
                    Task {
                        await led.record(pairs)
                        ProblemAlert.show(await led.takeProblem())
                    }
                }
            }
            // The old version gave **no feedback** on this path (copy/move had toasts, trash didn't); users only saw rows vanish.
            // On partial failure it's even more important to say how many succeeded, how many didn't, and the first reason.
            if receipt.failures.isEmpty {
                guard !items.isEmpty else { return }
                Toast.show(L10n.f("toast.trashedN", items.count), in: self.grid?.view.window)
            } else {
                Toast.show(L10n.f("toast.trashedPartial", items.count,
                                  receipt.failures.count, receipt.failures[0].message),
                           in: self.grid?.view.window)
            }
        }
    }

    func duplicate(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        run(OperationSpec(kind: .duplicate, sources: urls))
    }

    // MARK: Archives (compress / extract; ArchiveEngine pod, builds ArchiveOptions from Preferences archive defaults)

    /// Compresses the selection into one archive (format from settings; multi-source uses the localized default base name, single-source lets the node derive it from the name)
    /// A password makes it a zip whatever the setting says: tar.gz has no encryption.
    func compress(_ urls: [URL], password: String? = nil) {
        guard !urls.isEmpty else { return }
        let keepOriginal = Preferences.archiveKeepOriginal
        let options = ArchiveOptions(format: password == nil ? Preferences.archiveFormat : "zip", password: password,
                                     keepOriginal: keepOriginal)
        // Multi-source archive base name uses the localized "Archive" (the node packs under the common parent); single-source naming is left to the node, minus the extension
        let baseName = urls.count > 1 ? L10n.t("archive.defaultName") : nil
        run(OperationSpec(kind: .compress, sources: urls, newName: baseName, archiveOptions: options)) { [weak self] receipt in
            guard let self, let receipt else { return }
            let name = receipt.createdURLs.first?.lastPathComponent ?? ""
            Toast.show(L10n.f("toast.compressed", name), in: self.grid?.view.window)
            // Keep originals = false → after a successful archive, move the originals to the Trash (reuses the trash + undo path)
            if !keepOriginal { self.moveToTrash(urls) }
        }
    }

    /// Extracts the selected archives (into=nil extracts next to the archive; "Extract To…" passes a destination directory)
    func extract(_ urls: [URL], into directory: URL?) {
        let archives = urls.filter { ArchiveEngineNode.isSupportedArchive($0) }
        guard !archives.isEmpty else { NSSound.beep(); return }
        Task { @MainActor in
            var plain: [URL] = []
            for archive in archives {
                do {
                    switch try await archivePasswords.resolve(archive) {
                    case .notNeeded: plain.append(archive)
                    case .password(let password): runExtract([archive], into: directory, password: password)
                    case .cancelled: break
                    }
                } catch {
                    plain.append(archive)   // Unreadable: the extraction itself reports why
                }
            }
            if !plain.isEmpty { runExtract(plain, into: directory, password: nil) }
        }
    }

    private func runExtract(_ archives: [URL], into directory: URL?, password: String?) {
        let keepArchive = Preferences.extractKeepArchive
        let options = ArchiveOptions(password: password, keepOriginal: true, extractInto: directory,
                                     createWrapper: Preferences.extractCreateWrapper)
        run(OperationSpec(kind: .extract, sources: archives, archiveOptions: options)) { [weak self] receipt in
            guard let self, let receipt else { return }
            Toast.show(L10n.f("toast.extracted", receipt.createdURLs.count), in: self.grid?.view.window)
            // Keep archive = false → after a successful extract, move the archive to the Trash
            if !keepArchive { self.moveToTrash(archives) }
        }
    }

    /// Moves what the archive browser took out of an archive to its destination, through Transfer: conflicts ask as for any move.
    /// `onComplete` runs on every outcome, so the temporary folder always goes away.
    func landExtracted(_ urls: [URL], into directory: URL, onComplete: @escaping @MainActor () -> Void) {
        let destination = directory.standardizedFileURL
        guard !Self.isTrashDestination(destination) else {
            Toast.show(L10n.t("toast.notIntoTrash"), in: grid?.view.window)
            onComplete()
            return
        }
        run(OperationSpec(kind: .move, sources: urls, destination: destination)) { [weak self] receipt in
            if receipt != nil {
                Toast.show(L10n.f("toast.extracted", urls.count), in: self?.grid?.view.window)
            }
            onComplete()
        }
    }

    func newFolder(in directory: URL, revealIn list: FileRevealTarget?) {
        run(OperationSpec(kind: .newFolder, sources: [], destination: directory,
                          newName: L10n.t("newItem.folder"))) { receipt in
            if let url = receipt?.createdURLs.first { list?.prepareReveal(url, rename: true) }
        }
    }

    func newFile(in directory: URL, revealIn list: FileRevealTarget?) {
        run(OperationSpec(kind: .newFile, sources: [], destination: directory,
                          newName: L10n.t("newItem.file"))) { receipt in
            if let url = receipt?.createdURLs.first { list?.prepareReveal(url, rename: true) }
        }
    }

    /// Inline rename commit (FG-6: on failure the caller atomically rolls back the old name and shows red text in place)
    func rename(_ url: URL, to newName: String, completion: @escaping @MainActor (Bool) -> Void) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != url.lastPathComponent else { completion(true); return }
        Task { @MainActor in
            let id = await kernel.submit(OperationSpec(kind: .rename, sources: [url], newName: trimmed))
            let ok = await waitTerminal(id)
            if ok { reloadLists() }
            completion(ok)
        }
    }

    // MARK: F5 copy / F6 move to the other pane

    func copyToOtherPane(_ urls: [URL]) { transferToOtherPane(urls, move: false) }
    func moveToOtherPane(_ urls: [URL]) { transferToOtherPane(urls, move: true) }

    private func transferToOtherPane(_ urls: [URL], move: Bool) {
        guard !urls.isEmpty else { return }
        guard let dir = otherPaneDirectory() else { NSSound.beep(); return }
        // Shares one submission path with drag-and-drop and the stash shelf (no duplicate implementation)
        transfer(urls: urls, into: dir, move: move)
    }

    private func otherPaneDirectory() -> URL? {
        guard let grid else { return nil }
        let panes = grid.visiblePanes
        guard panes.count > 1 else { return nil }
        let next = panes[(grid.activePaneIndex + 1) % panes.count]
        return next.activeTab.browser.current
    }

    // MARK: Drag and drop (shared by list/breadcrumbs/stash shelf; Finder convention: move on same volume, copy across volumes, ⌥ forces copy)

    /// Submits a drop: decides the kind from the drag preference + ⌥ (auto = move on same volume, copy across; forceCopy = ⌥ forces copy)
    func dropTransfer(urls: [URL], into destination: URL, forceCopy: Bool,
                      onComplete: (@MainActor (Bool) -> Void)? = nil) {
        guard !urls.isEmpty else { onComplete?(false); return }
        let move = Self.effectiveMove(urls: urls, into: destination, optionCopy: forceCopy)
        transfer(urls: urls, into: destination, move: move, onComplete: onComplete)
    }

    /// The single decision of "move or copy" for a drop (shared by validateDrop's visual feedback and dropTransfer's actual submission):
    /// - auto: Finder convention: ⌥ forces copy, same volume moves, across volumes copies
    /// - copy: always copies
    /// - move: always moves on the same volume, degrades to copy across volumes (ignores ⌥)
    static func effectiveMove(urls: [URL], into destination: URL, optionCopy: Bool) -> Bool {
        let sameVolume = urls.allSatisfy { isSameVolume($0, destination) }
        switch Preferences.dragBehavior {
        case "copy": return false
        case "move": return sameVolume
        default:     return !optionCopy && sameVolume
        }
    }

    /// Explicit copy/move to a directory (used by stash shelf bulk actions; onComplete(true) means the operation finished)
    func transfer(urls: [URL], into destination: URL, move: Bool,
                  onComplete: (@MainActor (Bool) -> Void)? = nil) {
        guard !urls.isEmpty else { onComplete?(false); return }
        let dest = destination.standardizedFileURL
        // Defensive recheck: a directory must never go into itself or a descendant (the UI's validateDrop already blocks this; safety net here)
        guard urls.allSatisfy({ !Self.isSelfOrDescendant(destination: dest, ofSource: $0) }) else {
            NSSound.beep(); onComplete?(false); return
        }
        // Drops, F5/F6 and the stash all arrive here. Items placed in the Trash this way would have no ledger record and no undo.
        guard !Self.isTrashDestination(dest) else {
            Toast.show(L10n.t("toast.notIntoTrash"), in: grid?.view.window)
            onComplete?(false)
            return
        }
        // All items already in the destination: moving is a no-op; copying goes through a normal copy, triggering the self-source conflict panel (matches paste semantics, M27-B)
        if move, urls.allSatisfy({ $0.standardizedFileURL.deletingLastPathComponent().path == dest.path }) {
            onComplete?(false)
            return
        }
        run(OperationSpec(kind: move ? .move : .copy, sources: urls, destination: dest)) { [weak self] receipt in
            // Toast only on a successful landing (cancel/failure gives receipt==nil; failures have their own presentation)
            if receipt != nil {
                Toast.show(L10n.f(move ? "toast.movedN" : "toast.copiedN", urls.count),
                           in: self?.grid?.view.window)
            }
            onComplete?(receipt != nil)
        }
    }

    /// Whether destination is source itself or a descendant of it (refuses dropping a directory into itself)
    nonisolated static func isSelfOrDescendant(destination: URL, ofSource source: URL) -> Bool {
        let src = source.standardizedFileURL.path
        let dst = destination.standardizedFileURL.path
        return dst == src || dst.hasPrefix(src.hasSuffix("/") ? src : src + "/")
    }

    /// Whether a directory is a Trash or inside one, also when reached through a symlink.
    /// Not private so validateDrop can use it for its feedback.
    nonisolated static func isTrashDestination(_ destination: URL) -> Bool {
        TrashGuard.isInside(destination, anyOf: [
            TrashLocation.userTrash,
            TrashLocation.trash(for: destination),
            TrashLocation.trash(for: destination.resolvingSymlinksInPath()),
        ])
    }

    /// Same-volume check (unknown counts as cross-volume → copy, avoiding an accidental move)
    nonisolated static func isSameVolume(_ a: URL, _ b: URL) -> Bool {
        guard let va = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier,
              let vb = try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        else { return false }
        return va.isEqual(vb)
    }

    // MARK: Trash undo (moves trashed back to original; reuses move/rename semantics, no business branches in the kernel)

    private func registerRestoreUndo(_ items: [TrashedItem]) {
        undoManager.registerUndo(withTarget: self) { coord in
            MainActor.assumeIsolated { coord.restore(items) }
        }
        undoManager.setActionName(L10n.t("undo.trash"))
    }

    /// internal rather than private: Put Back reuses the same move-back chain (not a second copy,
    /// or the two would drift: undo could restore the original name while Put Back couldn't, the same bug fixed in only one place)
    func restore(_ items: [TrashedItem], onComplete: (@MainActor (RestoreOutcome) -> Void)? = nil) {
        // Redo moves back to the Trash only what really came out of it. It must be registered here, while
        // UndoManager is undoing, so it reads the outcome when it runs: `original` may hold an unrelated file by then.
        let outcome = RestoreRecord()
        undoManager.registerUndo(withTarget: self) { coord in
            MainActor.assumeIsolated { coord.moveToTrash(outcome.value.landed) }
        }
        undoManager.setActionName(L10n.t("undo.trash"))
        // One at a time: each item's "is the path free" check must see where the previous item landed
        Task { @MainActor in
            for item in items {
                let (step, landed) = await restoreOne(item)
                await trashLedger?.settle(step, for: item.trashed)
                if step != .notRestored { outcome.value.restored += 1 }
                if let landed { outcome.value.landed.append(landed) }
            }
            ProblemAlert.show(await trashLedger?.takeProblem())
            onComplete?(outcome.value)
        }
    }

    /// Moves one item back, then renames it only when the move proves that is safe (TrashRestorePolicy).
    /// Also returns where the item ended up, when that path holds only this item.
    private func restoreOne(_ item: TrashedItem) async -> (TrashRestoreStep, URL?) {
        let occupied = TrashRestorePolicy.isOccupied(TrashRestorePolicy.landedURL(of: item))
        let parent = item.original.deletingLastPathComponent()
        let receipt = await runToEnd(OperationSpec(kind: .move, sources: [item.trashed], destination: parent))
        // If the Trash renamed it because of a name clash → rename back to the original name after moving back
        let step = TrashRestorePolicy.step(after: receipt, of: item, landedWasOccupied: occupied)
        switch step {
        case .notRestored:
            return (step, nil)
        case .restored(let landed):
            return (step, landed)
        case .rename(let landed, let name):
            let renamed = await runToEnd(OperationSpec(kind: .rename, sources: [landed], newName: name))
            return (step, renamed?.createdURLs.first ?? landed)
        }
    }

    // MARK: Internal: submit + wait for terminal state + refresh

    private func run(_ spec: OperationSpec, onComplete: (@MainActor (OperationReceipt?) -> Void)? = nil) {
        Task { @MainActor in
            let id = await kernel.submit(spec)
            var receipt: OperationReceipt?
            for await p in await kernel.projections() where p.id == id {
                guard p.state.isTerminal else { continue }
                // Fetch the receipt on any terminal state, not just .completed: a partially failed run is .failed,
                // but the kernel has stored its receipt (holding what really landed). Fetching only on .completed
                // would throw away "what already got done" along with the state, losing all undo and reporting.
                receipt = await kernel.receipt(id)
                break
            }
            onComplete?(receipt)
            reloadLists()
        }
    }

    /// `run` for callers that must act on the outcome before starting the next operation.
    private func runToEnd(_ spec: OperationSpec) async -> OperationReceipt? {
        await withCheckedContinuation { done in
            run(spec) { done.resume(returning: $0) }
        }
    }

    private func waitTerminal(_ id: UUID) async -> Bool {
        for await p in await kernel.projections() where p.id == id {
            switch p.state {
            case .completed: return true
            case .failed, .cancelled: return false
            default: continue
            }
        }
        return false
    }

    /// Re-reads each visible pane's active list after an operation (real FS projection refresh)
    func reloadLists() {
        grid?.visiblePanes.forEach { $0.reloadActiveList() }
    }

    /// Redraw only (cut-dimming changed; no need to re-read the disk)
    private func redrawLists() {
        grid?.visiblePanes.forEach { $0.redrawActiveList() }
    }

    // MARK: Clipboard read/write

    private func writeToPasteboard(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
    }

    private func readPasteboardURLs() -> [URL] {
        let pb = NSPasteboard.general
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (pb.readObjects(forClasses: [NSURL.self], options: opts) as? [URL]) ?? []
    }
}
