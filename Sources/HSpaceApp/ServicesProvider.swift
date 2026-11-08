import AppKit
import HSpaceContracts
import ServiceRequests

// Services menu entries (L63): Show File Hashes, Batch Rename and Add to HSpace Stash, from Finder or any app that
// sells file selections. Support/Info.plist lists them under NSServices; NSApp.servicesProvider is the AppDelegate.

extension ServiceRejection {
    var message: String {
        switch self {
        case .nothingUsable: L10n.t("service.nothingUsable")
        case .onlyFolders: L10n.t("service.onlyFolders")
        case .missing(let name): L10n.f("service.missing", name)
        }
    }
}

enum ServiceRouting {
    /// The items in a form the batch rename sheet takes. Items in the Trash are refused: Put Back finds them by name.
    static func renameItems(_ items: [ServiceItem]) -> Result<[FileItem], ServiceRefusal> {
        guard !items.contains(where: { TrashLocation.isInsideTrash($0.url) }) else { return .failure(.inTrash) }
        return .success(items.map {
            FileItem(url: $0.url, name: $0.url.lastPathComponent, isDirectory: $0.isDirectory, isPackage: $0.isPackage,
                     isSymlink: false, isHidden: false, size: nil, modified: $0.modified, created: $0.created,
                     contentTypeID: nil)
        })
    }
}

enum ServiceRefusal: Error, Equatable {
    case plan(ServiceRejection)
    case inTrash
    case busy

    var message: String {
        switch self {
        case .plan(let rejection): rejection.message
        case .inTrash: L10n.t("service.inTrash")
        case .busy: L10n.t("service.busy")
        }
    }
}

extension AppDelegate {
    @objc func showHashesInHSpace(_ pboard: NSPasteboard, userData: String, error: NSErrorPointer) {
        perform(.showHashes, with: pboard) { items, wc, window in
            FileHashSheetController.present(files: items.map(\.url), in: window)
            return .success(())
        }
    }

    @objc func batchRenameInHSpace(_ pboard: NSPasteboard, userData: String, error: NSErrorPointer) {
        perform(.batchRename, with: pboard) { items, wc, window in
            ServiceRouting.renameItems(items).map { fileItems in
                BatchRenameSheetController.present(items: fileItems, ops: wc.renameOps, store: wc.renameStore, in: window)
            }
        }
    }

    @objc func addToHSpaceStash(_ pboard: NSPasteboard, userData: String, error: NSErrorPointer) {
        perform(.addToStash, with: pboard) { items, wc, _ in
            wc.stashShelf.add(items.map(\.url))
            return .success(())
        }
    }

    /// Reads the files the other app sent, checks them for `service`, and runs `body` in the front window, opening
    /// one at the first item's folder when there is none. Anything refused is said in that window.
    private func perform(_ service: HSpaceService, with pboard: NSPasteboard,
                         _ body: @escaping @MainActor ([ServiceItem], MainWindowController, NSWindow) -> Result<Void, ServiceRefusal>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        whenSessionReady { [weak self] in
            guard let self else { return }
            let plan = ServicePlan.items(for: service, from: urls)
            var folder = FileManager.default.homeDirectoryForCurrentUser
            if case .success(let items) = plan, let first = items.first { folder = first.url.deletingLastPathComponent() }
            let wc = activeMainWindowController() ?? openWindow(at: folder)
            guard let window = wc.window else { return }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            let outcome: Result<Void, ServiceRefusal>
            switch plan {
            case .failure(let rejection):
                outcome = .failure(.plan(rejection))
            case .success(let items):
                outcome = window.attachedSheet == nil || service == .addToStash ? body(items, wc, window) : .failure(.busy)
            }
            if case .failure(let refusal) = outcome { Toast.show(refusal.message, in: window) }
        }
    }
}
