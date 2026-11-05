import AppKit

/// What a drop handler reports to AppKit, so the cursor always shows what `dropTransfer` will really do.
/// `willMove` must come from `FileOpsCoordinator.effectiveMove`, the decision the submission itself uses.
enum DropFeedback {
    /// Whether a drop on `target` must be refused because it is a Trash. AppKit asks on every mouse move,
    /// so the message goes through `TrashDropNotice` rather than one toast per call.
    @MainActor
    static func refusesTrash(_ target: URL, in window: NSWindow?) -> Bool {
        guard FileOpsCoordinator.isTrashDestination(target) else { return false }
        if trashNotice.shouldShow() { Toast.show(L10n.t("toast.notIntoTrash"), in: window) }
        return true
    }

    @MainActor private static var trashNotice = RepeatLimiter(interval: 3)

    /// A move into the folder the items are already in is a no-op, so it is refused; a copy is allowed (it makes a duplicate).
    static func operation(willMove: Bool, urls: [URL], target: URL) -> NSDragOperation {
        guard willMove else { return .copy }
        let destPath = target.standardizedFileURL.path
        let alreadyThere = urls.allSatisfy { $0.standardizedFileURL.deletingLastPathComponent().path == destPath }
        return alreadyThere ? [] : .move
    }
}

/// Lets a repeated event through once per interval.
struct RepeatLimiter {
    let interval: TimeInterval
    private var last: Date?

    init(interval: TimeInterval) { self.interval = interval }

    mutating func shouldShow(now: Date = Date()) -> Bool {
        if let last, now.timeIntervalSince(last) < interval { return false }
        last = now
        return true
    }
}
