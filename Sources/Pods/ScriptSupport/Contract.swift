import Foundation

// ScriptSupport pod's sole public contract surface (Axiom 3): how AppleScript requests (L62) turn into what the app
// does, and the errors a script gets back. The app's scripting objects only call in here and apply the result.

/// An error a script sees, with the Apple event error number scripts test for
public struct ScriptError: Error, Equatable, Sendable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    /// fnfErr: the item named does not exist
    public static func notFound(_ path: String) -> ScriptError {
        ScriptError(code: -43, message: "\(path) does not exist.")
    }

    /// paramErr: the value is not something HSpace can use
    public static func badValue(_ message: String) -> ScriptError {
        ScriptError(code: -50, message: message)
    }

    /// errAENoSuchObject: an item to select is not in the folder the pane shows
    public static func notInFolder(_ name: String) -> ScriptError {
        ScriptError(code: -1728, message: "\(name) is not in the folder the pane shows.")
    }

    /// errAEEventFailed: there is no window to act on
    public static let noWindow = ScriptError(code: -10000, message: "HSpace has no browser window open.")
}

/// Where setting a pane's path takes it
public enum ScriptLocation: Equatable, Sendable {
    /// A folder: the pane shows it
    case folder(URL)
    /// A file or package: the pane shows its folder with it selected
    case item(URL, in: URL)
}

public enum ScriptPlan {
    /// The pane location a script asks for. Reads the disk: a script waits for its answer anyway.
    public static func location(for url: URL) -> Result<ScriptLocation, ScriptError> {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            return .failure(.badValue("A pane can only show a file or folder on this Mac."))
        }
        let target = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
            return .failure(.notFound(target.path))
        }
        if isDirectory.boolValue, !isPackage(target) { return .success(.folder(target)) }
        let parent = target.deletingLastPathComponent()
        return .success(.item(target, in: parent))
    }

    /// The items to select in a pane showing `folder`. Each must exist and sit directly in that folder.
    public static func selection(_ urls: [URL], in folder: URL) -> Result<[URL], ScriptError> {
        let base = folder.standardizedFileURL.path
        var picked: [URL] = []
        for url in urls {
            guard url.isFileURL else { return .failure(.badValue("Only files and folders can be selected.")) }
            let item = url.standardizedFileURL
            guard item.deletingLastPathComponent().path == base else { return .failure(.notInFolder(item.lastPathComponent)) }
            guard FileManager.default.fileExists(atPath: item.path) else { return .failure(.notFound(item.path)) }
            if !picked.contains(item) { picked.append(item) }
        }
        return .success(picked)
    }

    /// Files to add to or remove from the stash: file URLs only, each once, in order
    public static func stashItems(_ urls: [URL]) -> Result<[URL], ScriptError> {
        guard !urls.isEmpty else { return .failure(.badValue("Name at least one file or folder.")) }
        var picked: [URL] = []
        for url in urls {
            guard url.isFileURL, url.path.hasPrefix("/") else {
                return .failure(.badValue("Only files and folders can go on the stash shelf."))
            }
            let item = url.standardizedFileURL
            if !picked.contains(item) { picked.append(item) }
        }
        return .success(picked)
    }

    /// 1-based pane number to array index
    public static func paneIndex(_ number: Int, count: Int) -> Result<Int, ScriptError> {
        guard (1...max(count, 1)).contains(number), count > 0 else {
            return .failure(.badValue("There is no pane \(number); this window has \(count)."))
        }
        return .success(number - 1)
    }

    private static func isPackage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
    }
}
