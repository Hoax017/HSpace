import AppKit

/// Keeps a self-test run away from the user's preferences, bookmarks, stash and clipboard.
enum TestIsolation {
    #if DEBUG
    static var isActive: Bool { ProcessInfo.processInfo.environment["HSPACE_UITEST"] != nil }
    #else
    static var isActive: Bool { false }
    #endif

    /// Name of a defaults key that belongs with data a test run keeps apart from the user's.
    static func defaultsKey(_ key: String, isolated: Bool = isActive) -> String {
        isolated ? key + suffix : key
    }

    fileprivate static let suffix = ".uitest"
}

#if DEBUG

/// Preferences are read from `UserDefaults.standard` all over the app, and a debug build shares the release bundle id, so a
/// test run writes to the user's real domain. This puts the domain back afterwards. The snapshot lives inside the domain
/// itself, so a run that crashed is repaired by the next one. Keys ending in `.uitest` are the test run's own and stay,
/// because the frame scenario spans two launches.
struct DefaultsSandbox {
    let defaults: UserDefaults
    let domain: String

    private static let snapshotKey = "sandboxSnapshot" + TestIsolation.suffix

    static var standard: DefaultsSandbox {
        DefaultsSandbox(defaults: .standard,
                        domain: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)
    }

    func begin() {
        end()
        let user = (defaults.persistentDomain(forName: domain) ?? [:])
            .filter { !$0.key.hasSuffix(TestIsolation.suffix) }
        defaults.set(user, forKey: Self.snapshotKey)
        defaults.synchronize()
    }

    /// Does nothing when no snapshot is pending.
    func end() {
        guard let user = defaults.dictionary(forKey: Self.snapshotKey) else { return }
        let ownKeys = (defaults.persistentDomain(forName: domain) ?? [:])
            .filter { $0.key.hasSuffix(TestIsolation.suffix) && $0.key != Self.snapshotKey }
        defaults.setPersistentDomain(user.merging(ownKeys) { _, own in own }, forName: domain)
        defaults.synchronize()
    }
}

/// The self-test asserts on what Copy Path really leaves on the general pasteboard, so it has to hand the user's clipboard back.
struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(of pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            var contents: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { contents[type] = item.data(forType: type) }
            return contents
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.writeObjects(items.map { contents in
            let item = NSPasteboardItem()
            for (type, data) in contents { item.setData(data, forType: type) }
            return item
        })
    }
}

#endif
