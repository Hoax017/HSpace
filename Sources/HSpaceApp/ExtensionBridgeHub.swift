import AppKit
import ExtensionBridge
import FinderSync
import StashStore

/// Why a stash link from an extension was refused. Shown to the user, never repeating a path.
enum StashLinkRefusal: Error, Equatable {
    case link(StashLinkRejection)
    case path(ExternalOpenRejection)
    /// The secret could not be read or made, so no link can be trusted
    case noSecret

    var message: String {
        switch self {
        case .link(.untrusted), .link(.notAStashLink): L10n.t("extension.stash.untrusted")
        case .link(.tooManyItems): L10n.f("extension.stash.tooMany", StashLink.maxItems)
        case .link(.noItems), .link(.invalidPath): L10n.t("extension.stash.invalid")
        case .path(.remotePath): L10n.t("extension.stash.remote")
        case .path: L10n.t("extension.stash.invalid")
        case .noSecret: L10n.t("extension.stash.noSecret")
        }
    }
}

/// App side of the app extensions (L60 Finder Sync, L61 Share): publishes what they may read, and checks what they ask for.
/// Owns no state of its own: the snapshot it publishes is rebuilt from the stash shelf each time.
@MainActor
final class ExtensionBridgeHub {
    let publisher: BridgePublisher
    /// Publishes run one after another, so an older stash list can never land after a newer one
    private var lastPublish: Task<Void, Never>?
    var onError: ((String) -> Void)?

    init(supportDirectory: URL) {
        publisher = BridgePublisher(directory: BridgeLocation.directory(inSupport: supportDirectory))
    }

    /// The stash shelf changed: publish the paths of its items. Bookmarks are resolved off the main thread,
    /// because one can point at a slow volume.
    func stashChanged(_ items: [StashItem], store: StashStore) {
        let previous = lastPublish
        let publisher = publisher
        lastPublish = Task { [weak self] in
            await previous?.value
            let paths = await Task.detached { items.compactMap { store.resolve($0)?.path } }.value
            do {
                try await publisher.publish(stashedPaths: paths)
                DistributedNotificationCenter.default().postNotificationName(
                    BridgeLocation.changedNotification, object: nil, userInfo: nil, deliverImmediately: true)
            } catch {
                self?.onError?(error.localizedDescription)
            }
        }
    }

    /// Waits for the publishes queued so far (tests)
    func settle() async {
        await lastPublish?.value
    }

    /// The items a stash link names, once its secret and every path have passed
    func stashTargets(of link: URL) async -> Result<[URL], StashLinkRefusal> {
        let token: String
        do {
            token = try await publisher.currentToken()
        } catch {
            return .failure(.noSecret)
        }
        return Self.stashTargets(of: link, token: token)
    }

    /// Text only, never the disk: the link is checked before anything looks at a path it names
    nonisolated static func stashTargets(of link: URL, token: String) -> Result<[URL], StashLinkRefusal> {
        switch StashLink.parse(link, expectedToken: token) {
        case .failure(let rejection):
            return .failure(.link(rejection))
        case .success(let paths):
            for path in paths {
                if let rejection = LocalPathPolicy.check(path) { return .failure(.path(rejection)) }
            }
            return .success(paths.map { URL(fileURLWithPath: $0) })
        }
    }

    // MARK: Finder extension settings

    static var isFinderExtensionEnabled: Bool { FIFinderSyncController.isExtensionEnabled }

    static func showExtensionSettings() {
        FIFinderSyncController.showExtensionManagementInterface()
    }
}
