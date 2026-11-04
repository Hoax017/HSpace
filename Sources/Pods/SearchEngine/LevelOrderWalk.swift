import Foundation

/// Level-order (BFS) directory walk node: emitted depth is monotonically non-decreasing, so shallow entries are always seen first.
///
/// Why not `FileManager.enumerator` (a lazy pre-order DFS): after a depth-1 entry, DFS walks its entire subtree
/// before returning to the next depth-1 sibling. Measured on a real machine (root=~, 1.986M items):
///   `~/.claude`      DFS enumerated at 15.5s (item 750k)    / BFS 0.006s (item 104)
///   `~/.claude.json` DFS 34.2s (item 1.63M)                 / BFS 0.006s (item 214)
/// This is half the root cause of "visible but unsearchable": the hit was not suppressed, it simply had not been discovered yet.
/// Total tree cost BFS 43.6s vs DFS 42.4s (+2.8%), peak pending directories 28410 (about 2.2MB), both bounded.
/// It also naturally fits the existing product contract "local search prefers items near the root" (I-40).
///
/// Symlinks: not descended into. URL resource values return `isDirectory == false` for a symlink pointing to a directory
/// (measured), so the `isDir` check itself never queues it, matching enumerator semantics, no extra key needed.
enum LevelOrderWalk {
    /// Per-item callback; `visit` runs before the "descend or not" decision, so heavy directories **themselves** can still match
    /// (the old DFS version did `continue` in the skip branch first, so searching "Library"/"node_modules" could never find that directory itself).
    /// - Parameters:
    ///   - skipDirectoryNames: directories with these names are not descended into (still matched)
    ///   - shouldContinue: returning false stops immediately (cooperative cancellation)
    static func walk(root: URL,
                     skipDirectoryNames: Set<String>,
                     shouldContinue: () -> Bool,
                     visit: (_ url: URL, _ depth: Int, _ isDirectory: Bool) -> Void) {
        let fm = FileManager.default
        var frontier: [URL] = [root]
        var depth = 0
        while !frontier.isEmpty, shouldContinue() {
            depth += 1
            var next: [URL] = []
            for dir in frontier {
                guard shouldContinue() else { return }
                // One autoreleasepool per directory, and this is **not optional**.
                // contentsOfDirectory / resourceValues produce many autoreleased objects, and the scan runs in
                // Task.detached with no RunLoop to drain them, so they pile up until the scan ends.
                // Measured on a real machine (root=~, 1.94M items), peak RSS:
                //   old DFS enumerator 512MB / BFS without pool 1219MB / BFS with pool 51MB
                // Cost is +3% duration (42.6s → 44.0s). The frontier array itself takes only ~2MB, not the main cost.
                autoreleasepool {
                    let kids = (try? fm.contentsOfDirectory(
                        at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
                    for url in kids {
                        // Check cancellation per item: the old DFS checked once per item; if BFS checked only per directory,
                        // typing one more character would let the previous search burn through the current directory's children before stopping.
                        guard shouldContinue() else { return }
                        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                        visit(url, depth, isDir)
                        if isDir, !skipDirectoryNames.contains(url.lastPathComponent) {
                            next.append(url)
                        }
                    }
                }
            }
            frontier = next
        }
    }
}
