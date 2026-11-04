import Foundation

/// Single source of truth for Trash locations (user report: "hspace has no Trash feature").
///
/// A dedicated node rather than `.appendingPathComponent(".Trash")` scattered at call sites:
/// the deck button, Go menu, pane action and self-test all ask the same question and would otherwise drift apart.
/// Read-only path derivation; contains no write APIs (BG-1).
enum TrashLocation {
    /// The current user's Trash (`~/.Trash`).
    /// Note: `~/.Trash` itself has the hidden flag, but DirectoryReader's `.skipsHiddenFiles`
    /// filters the **listed entries**, not the directory being enumerated, so it browses fine without "Show Hidden Files"
    /// (measured: 15/17 items).
    static var userTrash: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
    }

    /// The Trash that **corresponds to** a location.
    /// The old version only had userTrash: browsing an external disk, the trash button "Open Trash" jumped back to the startup
    /// disk's `~/.Trash`, while files dragged in were placed by `fm.trashItem` in **that volume's** `.Trashes/<uid>`,
    /// so the button pointed somewhere other than where files went. Read-only path derivation; creates no directories (BG-1).
    static func trash(for url: URL) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let vol = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume,
              let homeVol = (try? home.resourceValues(forKeys: [.volumeURLKey]))?.volume,
              vol.standardizedFileURL.path != homeVol.standardizedFileURL.path
        else { return userTrash }
        let perVolume = vol.appendingPathComponent(".Trashes", isDirectory: true)
            .appendingPathComponent(String(getuid()), isDirectory: true)
        // If the volume has no (or no readable) per-user trash, fall back to the user Trash: degrade honestly, don't pretend
        return FileManager.default.fileExists(atPath: perVolume.path) ? perVolume : userTrash
    }

    /// Whether this URL is the Trash itself (user Trash only)
    static func isTrash(_ url: URL) -> Bool {
        url.standardizedFileURL.path == userTrash.standardizedFileURL.path
    }

    /// Whether this URL is the root of **some** Trash (the user Trash or the volume's per-user trash).
    /// The "Empty" button appears only at a root, as in Finder: it is hidden in subfolders of the Trash,
    /// where clicking "Empty" would suggest it clears only that level.
    static func isTrashRoot(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        return p == userTrash.standardizedFileURL.path
            || p == trash(for: url).standardizedFileURL.path
    }

    /// Whether this URL is **inside a Trash** (at any depth).
    /// Checking "is the parent the Trash" is not enough: `~/.Trash/folder/file` would bypass the guard,
    /// and trashItem would silently lift it from the subfolder to the Trash root, so the user sees the file "move by itself".
    static func isInsideTrash(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        // Both count: the user Trash and the per-user trash on the URL's volume
        for root in Set([userTrash.standardizedFileURL.path,
                         trash(for: url).standardizedFileURL.path]) {
            if p == root || p.hasPrefix(root.hasSuffix("/") ? root : root + "/") { return true }
        }
        return false
    }
}
