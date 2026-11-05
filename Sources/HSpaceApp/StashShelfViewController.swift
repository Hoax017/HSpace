import AppKit
import StashStore

/// Stash shelf actions (action rows at the end of the group; FG-1: an empty shelf shows none of these rows)
enum StashAction {
    case copyHere   // Copy the whole stash to the current pane
    case moveHere   // Move the whole stash to the current pane (clears moved items afterwards)
    case airdrop    // AirDrop the whole stash

    var titleKey: String {
        switch self {
        case .copyHere: "stash.copyHere"
        case .moveHere: "stash.moveHere"
        case .airdrop: "stash.airdrop"
        }
    }

    var symbolName: String {
        switch self {
        case .copyHere: "doc.on.doc"
        case .moveHere: "arrow.right.square"
        case .airdrop: "dot.radiowaves.left.and.right"
        }
    }
}

/// Stash shelf controller (spec five-tuple: Decision Owner of stash shelf content):
/// the UI only sends Commands. Add/remove/clear commit through the StashStore pod; bulk copy/move goes through FileOpsCoordinator,
/// which builds an OperationSpec for the kernel (BG-1: no write-type file APIs in this layer). Rows appear in the sidebar "Stash Shelf" group.
@MainActor
final class StashShelfController {
    let store: StashStore
    /// In-memory projection (the sidebar builds rows from it; authoritative state lives in the StashStore actor)
    private(set) var items: [StashItem] = []

    /// Content changed → rebuild the sidebar
    var onChange: (() -> Void)?
    /// In-place error presentation (banner at the bottom of the sidebar; no modal alerts)
    var onError: ((String) -> Void)?
    /// File-operation bridge and pane grid (source of the "current pane" destination), injected by MainWindowController
    weak var coordinator: FileOpsCoordinator?
    weak var grid: PaneGridController?

    init(store: StashStore) {
        self.store = store
    }

    func start() {
        Task {
            await refresh()
            ProblemAlert.show(await store.takeProblem())
        }
    }

    // MARK: Add/remove/clear (all committed serially through the StashStore actor)

    func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task {
            do {
                try await store.add(urls)
                Toast.show(L10n.f("toast.stashed", urls.count), in: grid?.view.window)
            } catch { onError?(error.localizedDescription) }
            await refresh()
        }
    }

    func remove(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        Task {
            do { try await store.remove(ids: ids) } catch { onError?(error.localizedDescription) }
            await refresh()
        }
    }

    func clearAll() {
        Task {
            do { try await store.clear() } catch { onError?(error.localizedDescription) }
            await refresh()
        }
    }

    // MARK: Bulk actions (action rows at the end of the group)

    func perform(_ action: StashAction) {
        switch action {
        case .copyHere: transferAll(move: false)
        case .moveHere: transferAll(move: true)
        case .airdrop: airdropAll()
        }
    }

    /// Copies/moves the whole stash to the current pane; clears moved items once the move finishes
    private func transferAll(move: Bool) {
        let pairs: [(id: UUID, url: URL)] = items.compactMap { item in
            store.resolve(item).map { (item.id, $0) }
        }
        guard !pairs.isEmpty, let coordinator, let grid else { NSSound.beep(); return }
        let destination = grid.activePane.activeTab.browser.current
        coordinator.transfer(urls: pairs.map(\.url), into: destination, move: move) { [weak self] ok in
            guard ok, move else { return }
            self?.remove(ids: pairs.map(\.id))
        }
    }

    /// AirDrops the whole stash (on the resolved real URLs; failures show as an in-place banner)
    private func airdropAll() {
        let urls = items.compactMap { store.resolve($0) }
        guard !urls.isEmpty else { NSSound.beep(); return }
        guard let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: urls) else {
            onError?(L10n.t("stash.airdropFailed"))
            return
        }
        service.perform(withItems: urls)
    }

    // MARK: Private

    private func refresh() async {
        items = await store.all()
        onChange?()
    }
}
