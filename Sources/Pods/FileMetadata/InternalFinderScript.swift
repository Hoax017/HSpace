import Foundation

/// Asks Finder to set the comment through `osascript`. A separate process, because Finder can stall an Apple Event for a
/// long time, and the values travel as arguments, so no name or comment is ever read as script text.
public struct OsascriptFinderComments: FinderCommentPushing {
    private let timeout: Duration

    public init(timeout: Duration = .seconds(30)) {
        self.timeout = timeout
    }

    /// Arguments of the call: the comment, then the paths
    public static func arguments(comment: String, urls: [URL]) -> [String] {
        let script = [
            "on run argv",
            "set theComment to item 1 of argv",
            "tell application \"Finder\"",
            "repeat with thePath in rest of argv",
            "set comment of (POSIX file (thePath as text) as alias) to theComment",
            "end repeat",
            "end tell",
            "end run",
        ]
        return script.flatMap { ["-e", $0] } + [comment] + urls.map(\.path)
    }

    public func push(comment: String, to urls: [URL]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = Self.arguments(comment: comment, urls: urls)
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        let watchdog = Task { [timeout] in
            try await Task.sleep(for: timeout)
            process.terminate()
        }
        defer { watchdog.cancel() }
        do {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
                process.terminationHandler = { _ in done.resume() }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    done.resume(throwing: error)
                }
            }
        } catch {
            throw MetadataError(.transient, "Could not reach Finder: \(error.localizedDescription)")
        }
        guard process.terminationStatus != 0 else { return }
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        // -1743 is macOS saying the user has not allowed HSpace to control Finder
        throw MetadataError(.external, message.contains("-1743")
            ? "HSpace is not allowed to control Finder (System Settings, Privacy & Security, Automation)"
            : "Finder did not accept the comment")
    }
}
