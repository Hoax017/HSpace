import Foundation
import HSpaceContracts

// WindowRules pod's sole public contract surface (Axiom 3): what happens to windows and workspace tabs at launch, on a
// new window and on closing the last tab, and the apps in front of which HSpace's global triggers stay quiet.
// Pure decisions: the app reads the stored choices and acts on the answers.

/// What launching HSpace opens
public enum LaunchWindows: String, Sendable, CaseIterable {
    /// The windows and tabs open when HSpace last quit
    case restore
    /// One window at the home folder
    case home
}

/// Where File > New Window opens
public enum NewWindowFolder: String, Sendable, CaseIterable {
    case home
    /// The folder of the front window's active pane
    case current
}

/// What closing the last workspace tab of a window does
public enum LastTabClose: String, Sendable, CaseIterable {
    case closeWindow
    /// The window stays, with one tab at the home folder
    case keepWindow
}

public struct WindowOptions: Sendable, Equatable {
    public var launch: LaunchWindows
    public var newWindow: NewWindowFolder
    public var lastTab: LastTabClose
    public var quitAfterLastWindow: Bool

    public init(launch: LaunchWindows = .restore, newWindow: NewWindowFolder = .home,
                lastTab: LastTabClose = .closeWindow, quitAfterLastWindow: Bool = false) {
        self.launch = launch
        self.newWindow = newWindow
        self.lastTab = lastTab
        self.quitAfterLastWindow = quitAfterLastWindow
    }

    /// Stored words a later or earlier version does not know fall back to the default, one option at a time
    public init(launch: String?, newWindow: String?, lastTab: String?, quitAfterLastWindow: Bool?) {
        self.init(launch: launch.flatMap(LaunchWindows.init(rawValue:)) ?? .restore,
                  newWindow: newWindow.flatMap(NewWindowFolder.init(rawValue:)) ?? .home,
                  lastTab: lastTab.flatMap(LastTabClose.init(rawValue:)) ?? .closeWindow,
                  quitAfterLastWindow: quitAfterLastWindow ?? false)
    }

    /// The folder a new window opens at. A current folder that is gone, or not a folder, gives home.
    public func newWindowFolder(home: URL, current: URL?, isFolder: (URL) -> Bool) -> URL {
        guard newWindow == .current, let current, current.isFileURL, isFolder(current) else { return home }
        return current
    }

    /// Whether a saved session is reopened at launch. With nothing saved there is nothing to reopen.
    public func restoresSession(hasSavedWindows: Bool) -> Bool {
        launch == .restore && hasSavedWindows
    }
}

/// Apps in front of which the global hotkey and the drag-shake gesture do nothing, so their own shortcuts and drags stay theirs.
/// Bundle ids compare without regard to case, as macOS does.
public struct AppExclusions: Sendable, Equatable {
    /// Sorted, free of repeats, and every one a well-formed bundle id
    public private(set) var bundleIDs: [String]

    /// Ill-formed and repeated ids are dropped
    public init(_ ids: [String] = []) {
        bundleIDs = []
        for id in ids { add(id) }
    }

    public static func isBundleID(_ text: String) -> Bool {
        guard (1...255).contains(text.count), !text.hasPrefix("."), !text.hasSuffix("."), !text.contains("..") else { return false }
        return text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }

    public var isEmpty: Bool { bundleIDs.isEmpty }

    public func excludes(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleIDs.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    /// False when the id is ill-formed or already listed
    @discardableResult
    public mutating func add(_ bundleID: String) -> Bool {
        guard Self.isBundleID(bundleID), !excludes(bundleID) else { return false }
        bundleIDs = (bundleIDs + [bundleID]).sorted { $0.lowercased() < $1.lowercased() }
        return true
    }

    public mutating func remove(_ bundleID: String) {
        bundleIDs.removeAll { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    /// Whether the global triggers should stand down. HSpace itself is never excluded: its triggers must work in front of it.
    public func silences(frontmost: String?, own: String?) -> Bool {
        guard let frontmost else { return false }
        if let own, own.caseInsensitiveCompare(frontmost) == .orderedSame { return false }
        return excludes(frontmost)
    }
}
