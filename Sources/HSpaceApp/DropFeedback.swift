import AppKit

/// What a drop handler reports to AppKit, so the cursor always shows what `dropTransfer` will really do.
/// `willMove` must come from `FileOpsCoordinator.effectiveMove`, the decision the submission itself uses.
enum DropFeedback {
    /// A move into the folder the items are already in is a no-op, so it is refused; a copy is allowed (it makes a duplicate).
    static func operation(willMove: Bool, urls: [URL], target: URL) -> NSDragOperation {
        guard willMove else { return .copy }
        let destPath = target.standardizedFileURL.path
        let alreadyThere = urls.allSatisfy { $0.standardizedFileURL.deletingLastPathComponent().path == destPath }
        return alreadyThere ? [] : .move
    }
}
