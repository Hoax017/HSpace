import Foundation

/// Private concern: box for non-Sendable NotificationCenter observer tokens
/// removeObserver is thread-safe (guaranteed by Foundation), so @unchecked Sendable holds
final class ObserverBox: @unchecked Sendable {
    private let center: NotificationCenter
    private let lock = NSLock()
    private var tokens: [any NSObjectProtocol]

    init(center: NotificationCenter, tokens: [any NSObjectProtocol]) {
        self.center = center
        self.tokens = tokens
    }

    func removeAll() {
        lock.lock()
        let toRemove = tokens
        tokens = []
        lock.unlock()
        for t in toRemove { center.removeObserver(t) }
    }

    deinit { removeAll() }
}
