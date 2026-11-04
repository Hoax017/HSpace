import Foundation

/// Per-pane browsing state: current location plus back/forward history stacks (runtime form of the spec's session data contract)
@MainActor
final class BrowserState {
    private(set) var current: URL
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []

    init(url: URL) {
        self.current = url
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { current.standardizedFileURL.path != "/" }

    /// Back/forward history, most recent first, for the long-press navigation history menu (§3)
    var backHistory: [URL] { backStack.reversed() }
    var forwardHistory: [URL] { forwardStack.reversed() }

    /// Jump to back-history item `index` (0 = most recent): steps back index+1 times, pushing each path onto the forward stack (browser semantics)
    @discardableResult
    func jumpBack(to index: Int) -> URL? {
        guard index >= 0, index < backStack.count else { return nil }
        var last: URL?
        for _ in 0...index { last = goBack() }
        return last
    }

    /// Jump to forward-history item `index` (0 = most recent): steps forward index+1 times
    @discardableResult
    func jumpForward(to index: Int) -> URL? {
        guard index >= 0, index < forwardStack.count else { return nil }
        var last: URL?
        for _ in 0...index { last = goForward() }
        return last
    }

    /// New navigation: clears the forward stack (browser semantics)
    func navigate(to url: URL) {
        // Different spellings of the same directory must not be pushed onto the back stack twice: `/a/b` vs `/a/b/`, or forms with `.`/`..`
        // never compare equal as raw URLs (absoluteString differs), so the same directory would enter history and
        // ⌘[ would seem to do nothing. Pasting a trailing-slash path into the address bar is the easiest way to hit this.
        // Compare standardizedFileURL only (pure string); do **not** resolve symlinks, which needs a stat
        // and would stall the navigation hot path on a dead network volume (same reason PathEditorField moved resolution to the background).
        guard url.standardizedFileURL.path != current.standardizedFileURL.path else { return }
        backStack.append(current)
        forwardStack.removeAll()
        current = url
    }

    func goBack() -> URL? {
        guard let prev = backStack.popLast() else { return nil }
        forwardStack.append(current)
        current = prev
        return prev
    }

    func goForward() -> URL? {
        guard let next = forwardStack.popLast() else { return nil }
        backStack.append(current)
        current = next
        return next
    }

    func goUp() -> URL? {
        guard canGoUp else { return nil }
        let parent = current.deletingLastPathComponent().standardizedFileURL
        navigate(to: parent)
        return parent
    }
}
