import AppKit
import UniformTypeIdentifiers

/// Finder replacement integration: registers HSpace as the default opener for public.folder.
/// Honest limitation (same as QSpace): NSWorkspace.activateFileViewerSelecting-style
/// "Reveal in Finder" is hard-coded to Finder and cannot be intercepted; what we can take over is the LaunchServices
/// folder-open path (the open command, third-party apps' "Open Folder").
@MainActor
enum FinderIntegration {
    /// Whether the default public.folder handler is already this app (the settings page shows the status as is;
    /// should a future macOS unlock public.folder, the status turns green by itself).
    static var isDefaultFolderHandler: Bool {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: .folder) else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    // Note: there used to be a requestDefaultFolderHandler to claim the default folder handler, but macOS locks public.folder
    // to Finder: setDefaultApplication(toOpen: .folder) always returns paramErr(-50), tested even with a notarized
    // third-party app. That method was dead code that could only fail, so it was removed; the settings page (I-25) now states the status honestly instead of offering a button that always fails.

    /// Opens the Full Disk Access pane in System Settings (TCC guidance).
    /// Runs a read-only probe first: the attempt to access a protected directory makes TCC add HSpace to the FDA list by itself
    /// (the user just flips the switch, no need to click "+"; the same mechanism by which other apps "appear in the list automatically").
    static func openFullDiskAccessSettings() {
        _ = hasFullDiskAccess()
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }

    /// Full Disk Access probe (read-only, no BG-1 violation): tries to list TCC-protected directories (Safari/Mail).
    /// Listing succeeds (even when empty) = granted; when denied contentsOfDirectory throws = not granted.
    static func hasFullDiskAccess() -> Bool {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        for probe in ["Library/Safari", "Library/Mail"] {
            let url = home.appendingPathComponent(probe)
            var isDir: ObjCBool = false
            // The directory itself can be stat'ed (TCC only blocks reading contents); skip it if missing (Mail never set up, etc.)
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if (try? fm.contentsOfDirectory(atPath: url.path)) != nil { return true }
        }
        return false
    }

    // MARK: Reveal takeover (I-28: the NSFileViewer global key, same mechanism as QSpace, proven by experiment 2026-08-26)
    // `open -R` and third-party "open file location" route through this key; plain "open folder" stays locked to Finder by the OS.

    /// The three states of the Reveal handler
    enum RevealHandler: Equatable {
        case hspace
        case finder
        /// Points at another bundle id; resolvable=false means a stale leftover (such as a deleted QSpace), and "open location" then does nothing
        case other(id: String, resolvable: Bool)
    }

    static var revealHandler: RevealHandler {
        guard let id = RevealSetting.system.handler else { return .finder }
        if id == "com.hoax017.hspace" { return .hspace }
        let resolvable = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
        return .other(id: id, resolvable: resolvable)
    }

    /// Turn Reveal takeover on/off: writes/removes the global NSFileViewer key (takes effect at once, no system component restart needed)
    static func setRevealTakeover(_ on: Bool) {
        RevealSetting.system.set(handler: on ? "com.hoax017.hspace" : nil)
    }

    /// Gives Reveal back to Finder from any state, including `.other`, where the takeover checkbox cannot do it.
    /// Throws `RevealSettingError` if the setting did not change.
    static func restoreSystemReveal() throws {
        try RevealSetting.system.restoreSystemDefault()
    }
}
