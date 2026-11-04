import AppKit
import PathComplete

/// Path editor: opened by ⌘L/clicking blank space; completes as you type (PathComplete pod); Enter navigates, Esc cancels
@MainActor
final class PathEditorField: NSTextField, NSTextFieldDelegate {
    /// Destination is a directory -> enter it
    var onCommit: ((URL) -> Void)?
    /// Destination is a file, or a package such as .app/.bundle ("a directory on disk, one thing to the user") -> go to the parent and select it (Finder semantics)
    var onRevealFile: ((URL) -> Void)?
    var onCancel: (() -> Void)?
    /// Reset on focus loss (cleared by delete, clicked elsewhere, switched away from the app): the breadcrumb shows the current directory again, never leaving a blank
    var onReset: (() -> Void)?
    /// In-place text feedback for invalid paths (no alerts: spec craftsmanship invariant)
    var onInvalid: ((String) -> Void)?
    /// Base for resolving relative paths = the current browsing directory (the process CWD means nothing to a file manager)
    var baseDirectory: (() -> URL)?

    private let completer: any PathCompleting = PathCompleter()
    private var completing = false
    /// Whether controlTextDidChange is on the stack (used to prove complete fires outside the text change transaction)
    private var inTextDidChange = false
    /// A commit was just rejected (invalid path): Enter makes AppKit end the editing session, and the normal focus-loss reset
    /// would close the address bar along with the error just shown: one typo throws the user out of the field before they read the error.
    /// Finder's ⌘⇧G keeps you in the field to fix it in place; this matches that.
    private var rejectedJustNow = false
    /// Previous text length (UTF-16): tells "user typed a character" from "a paste poured in"
    private var lastTextLength = 0
    /// I-54 probe: number of times completion actually fired (verifies paste does not pop up completion)
    private(set) var uiTestCompletionTriggerCount = 0
    /// Commit resolution is running in the background (repeated Enter does not stack)
    private var resolving = false
    /// I-30 probe: candidate count of the last completion
    private(set) var uiTestLastCompletionCount = -1
    /// I-30 probe: whether the last completion fired **outside** the text change transaction (true = deferred; false under the synchronous bug)
    private(set) var uiTestCompletionWasDeferred = false

    init() {
        super.init(frame: .zero)
        delegate = self
        font = .monospacedSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
        placeholderString = L10n.t("addressbar.placeholder")
        cell?.usesSingleLineMode = true
        cell?.isScrollable = true
        registerForDraggedTypes([.fileURL])   // dragging a file/folder in fills in its path
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    func beginEditing(with path: String) {
        rejectedJustNow = false
        stringValue = path
        lastTextLength = (path as NSString).length   // programmatic assignment sends no controlTextDidChange, so the baseline must be aligned by hand
        window?.makeFirstResponder(self)
        // ⌘L means "change the address": select the whole path so typing/pasting replaces it (same as Finder ⌘⇧G / Safari)
        currentEditor()?.selectAll(nil)
    }

    // MARK: Path resolution (reduces all the odd forms found on the clipboard to one destination)

    enum Resolution: Equatable {
        case directory(URL)     // enter
        case file(URL)          // go to parent and select (including .app/.bundle packages)
        case unreadable(URL)    // exists but no read permission
        case notFound           // none of the candidate interpretations exist
        case empty              // empty input = cancel
    }

    /// Path strings pasted into the address bar come in all forms: Finder/Safari copy links as `file:///…` (with spaces percent-
    /// encoded as %20), terminals and text editors copy trailing newlines, paths dragged into a terminal carry backslash escapes, some people type quotes.
    /// The old code only did `trimmingCharacters(in: .whitespaces)` (**without \n**) + `~` expansion, hence the user's
    /// "sometimes pasting a folder won't jump, very strange": not magic, it depends on which form is on the clipboard.
    ///
    /// This expands the input into a list of candidate interpretations; the caller takes the first that really exists on disk. **The literal candidate always comes first**,
    /// so files whose names really contain backslashes/quotes are not harmed by "clever" unescaping.
    nonisolated static func candidates(_ raw: String, base: URL?) -> [String] {
        var out: [String] = []
        func push(_ candidate: String) {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let expanded = (trimmed as NSString).expandingTildeInPath
            let absolute = expanded.hasPrefix("/")
                ? expanded
                : (base.map { $0.appendingPathComponent(expanded).path } ?? expanded)
            let standardized = (absolute as NSString).standardizingPath
            // Disk has NFD, the clipboard often gives NFC: try both Unicode normalization forms (CJK and accented names always hit this)
            for form in [standardized,
                         standardized.precomposedStringWithCanonicalMapping,
                         standardized.decomposedStringWithCanonicalMapping]
            where !out.contains(form) {
                out.append(form)
            }
        }

        let source = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return [] }
        push(source)                                                    // 1. literal (highest priority)
        if source.lowercased().hasPrefix("file://") {                   // 2. file:// URL from Finder/Safari
            if let url = URL(string: source), url.isFileURL { push(url.path) }
            if let decoded = source.removingPercentEncoding { push(String(decoded.dropFirst(7))) }
            push(String(source.dropFirst(7)))
        }
        if let decoded = source.removingPercentEncoding, decoded != source { push(decoded) }  // 3. bare percent encoding
        if source.count >= 2, let head = source.first, let tail = source.last,                // 4. paired quotes
           (head == "\"" && tail == "\"") || (head == "'" && tail == "'") {
            push(String(source.dropFirst().dropLast()))
        }
        if source.contains("\\") {                                      // 5. backslash escapes as dragged into a terminal
            var unescaped = ""
            var escaping = false
            for ch in source {
                if escaping { unescaped.append(ch); escaping = false }
                else if ch == "\\" { escaping = true }
                else { unescaped.append(ch) }
            }
            push(unescaped)
        }
        return out
    }

    /// Resolves the destination of the current input. Pure disk reads with no side effects, so self-tests can assert on it directly.
    func resolve(_ raw: String) -> Resolution {
        Self.resolve(raw, base: baseDirectory?())
    }

    /// Pure resolution independent of instance state (**must be callable off the main thread**: stat on a dead network volume / automount point
    /// can block for tens of seconds, which on the main thread beach-balls the whole app).
    nonisolated static func resolve(_ raw: String, base: URL?) -> Resolution {
        let list = candidates(raw, base: base)
        guard !list.isEmpty else { return .empty }
        let fm = FileManager.default
        for path in list {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
                // Broken symlink: fileExists follows the link and says false, yet the link is plainly visible in the list.
                // attributesOfItem has lstat semantics (looks only at the link itself), so treat it as a file: go to the parent and select it.
                if (try? fm.attributesOfItem(atPath: path)) != nil {
                    return .file(caseCanonical(URL(fileURLWithPath: path)))
                }
                continue
            }
            let url = caseCanonical(URL(fileURLWithPath: path))
            // Packages such as .app/.bundle/.rtfd: directories on disk, but "one thing" to the user; select rather than drill in, per Finder semantics
            let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
            guard isDir.boolValue, !isPackage else { return .file(url) }
            guard fm.isReadableFile(atPath: path) else { return .unreadable(url) }
            return .directory(url)
        }
        return .notFound
    }

    /// Case normalization. APFS/HFS+ are case-insensitive by default: the user's casing may differ from disk, and using it verbatim makes the breadcrumb show
    /// the wrong name and name-based lookup miss. **Adopt the canonical path only when it differs "by case alone"**: `canonicalPath`
    /// also resolves symlinks (`/tmp` -> `/private/tmp`), which would change the path levels the user sees; that is not wanted here.
    nonisolated static func caseCanonical(_ url: URL) -> URL {
        guard let canonical = (try? url.resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath,
              canonical != url.path,
              canonical.compare(url.path, options: .caseInsensitive) == .orderedSame
        else { return url }
        return URL(fileURLWithPath: canonical)
    }

    // MARK: Completion (complete: fires as you type, reentrancy guarded)

    func controlTextDidChange(_ notification: Notification) {
        rejectedJustNow = false   // the user has edited the path, so the last rejection is over (keeps a stale flag from swallowing a later real focus-loss reset)
        let newLength = (stringValue as NSString).length
        let typedOneChar = newLength == lastTextLength + 1
        lastTextLength = newLength
        guard !completing, currentEditor() is NSTextView else { return }
        // No completion on paste (several characters at once). This is the second true cause of the user's "sometimes when I ⌘L paste a folder it won't jump,
        // very strange": the completion popup takes over the event loop and eats the Enter right after it (accepting a candidate instead of navigating).
        // Why "sometimes": PathCompleter lists only directories, so pasting a folder path always has candidates and a popup; pasting an .apk has none and no popup.
        // Typing by hand (+1) completes as usual; the I-30 contract "candidates on the first key" is unaffected.
        guard typedOneChar else { return }
        // I-30: complete(nil) must fire **deferred to the next runloop**, never synchronously inside controlTextDidChange.
        // Called synchronously, the first completion popup is swallowed by the text change transaction (no completion on the first key; it takes a second one);
        // async dispatch lets the text change settle first, and the popup appears on the first key.
        // completing must be set **at scheduling time**: reading it (the guard above) and writing it are a runloop hop apart,
        // and two text changes in one runloop pass would both clear the guard, stacking two completions (nested event loops).
        completing = true
        inTextDidChange = true
        defer { inTextDidChange = false }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { self.completing = false }   // reset on any early return too, or a stale flag kills completion for good
            guard let editor = self.currentEditor() as? NSTextView else { return }
            // UITEST headless environment: the AppKit completion popup enters a nested event loop with no event to leave it (main thread stack shows
            // NSTextViewCompletionController hanging and starving the watchdog). Self-tests only verify the "fired outside the transaction" contract and the candidate count
            //(the completions callback still runs), with no real popup; the product path is unchanged.
            if UISelfTest.isEnabled {
                var idx = -1
                _ = self.control(self, textView: editor,
                                 completions: [],
                                 forPartialWordRange: editor.rangeForUserCompletion,
                                 indexOfSelectedItem: &idx)
            } else {
                editor.complete(nil)
            }
        }
    }

    func control(_ control: NSControl, textView: NSTextView,
                 completions words: [String], forPartialWordRange charRange: NSRange,
                 indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String] {
        index.pointee = -1
        uiTestCompletionTriggerCount += 1
        // I-30 contract check: complete must fire after controlTextDidChange returns (otherwise the first-key popup is swallowed)
        uiTestCompletionWasDeferred = !inTextDidChange
        // Complete on the whole line (the system default splits by word; paths need whole-line semantics)
        let full = completer.complete(stringValue)
        uiTestLastCompletionCount = full.count
        // The PathComplete contract returns **complete absolute paths**, but AppKit writes a candidate back only to charRange (the last word).
        // Returned as is, accepting a candidate yields junk like /Users/me//Users/me/Downloads/, and the next Enter always shakes.
        // Trim here to "the part that belongs in charRange" so accepting gives the right path. All lengths are NSString lengths, so non-ASCII names stay aligned.
        let text = stringValue as NSString
        guard charRange.location != NSNotFound, NSMaxRange(charRange) <= text.length else { return [] }
        let head = text.substring(to: charRange.location) as NSString
        return full.compactMap { candidate in
            let ns = candidate as NSString
            // When a candidate does not match "the part before charRange" (such as typing `~` with a candidate that is the expanded absolute path),
            // no "replace this part" edit can produce the right path, so give no candidate and no popup.
            // The user can still press Tab for our own completion: that path rewrites stringValue as a whole and is always right.
            guard ns.hasPrefix(head as String) else { return nil }
            return ns.substring(from: head.length)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            submit()
            return true
        case #selector(NSResponder.insertTab(_:)):
            // In a path field Tab means "complete", not "move focus" (same for Finder ⌘⇧G / terminals / browser address bars).
            // The old behavior was AppKit's default focus move: the field lost focus and reset, and the half-typed path evaporated with the editing state.
            completeToCommonPrefix()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        default:
            return false
        }
    }

    /// Commits the current input. Resolving reads the disk and **must leave the main thread**: stat on a dead network volume / automount point can block for tens of seconds,
    /// which on the main thread beach-balls the whole app. Editing state stays on meanwhile; once resolved, it returns to the main thread to land.
    private func submit() {
        guard !resolving else { return }          // repeated Enter does not stack resolutions
        let raw = stringValue
        let base = baseDirectory?()
        resolving = true
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Self.resolve(raw, base: base)
            }.value
            guard let self else { return }
            self.resolving = false
            // The user may have changed the content or closed the address bar during resolution: the result is void; do not drag them somewhere unrelated
            guard !self.isHidden, self.stringValue == raw else { return }
            switch result {
            case .empty:                 self.onCancel?()
            case .directory(let url):    self.onCommit?(url)
            case .file(let url):         self.onRevealFile?(url)
            case .unreadable:            self.reject(L10n.t("addressbar.error.denied"))
            case .notFound:              self.reject(L10n.t("addressbar.error.notFound"))
            }
        }
    }

    /// Tab completion: a single candidate is filled in; several complete to the longest common prefix; no progress means a beep (ambiguous, let the user type more).
    private func completeToCommonPrefix() {
        let candidates = completer.complete(stringValue)
        guard !candidates.isEmpty else { NSSound.beep(); return }
        let target = candidates.count == 1 ? candidates[0] : Self.longestCommonPrefix(candidates)
        let current = stringValue as NSString
        guard (target as NSString).length > current.length, target.hasPrefix(stringValue) else {
            NSSound.beep(); return
        }
        stringValue = target
        lastTextLength = (target as NSString).length
        currentEditor()?.moveToEndOfLine(nil)
    }

    nonisolated static func longestCommonPrefix(_ items: [String]) -> String {
        guard var prefix = items.first else { return "" }
        for item in items.dropFirst() {
            while !prefix.isEmpty, !item.hasPrefix(prefix) { prefix.removeLast() }
            if prefix.isEmpty { break }
        }
        return prefix
    }

    // MARK: Drag and drop (turns a dragged file/folder into a path; Finder's Go panel and browser address bars all support this)

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        droppedURL(from: sender) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        acceptDrop(from: sender.draggingPasteboard)
    }

    /// Drop landing (a seam decoupled from NSDraggingInfo: self-tests drive it with a private NSPasteboard, never touching the user's real clipboard)
    @discardableResult
    func acceptDrop(from pasteboard: NSPasteboard) -> Bool {
        guard let url = fileURL(on: pasteboard) else { return false }
        beginEditing(with: url.path)   // fill in and select all: press Return to go, or keep editing
        return true
    }

    /// First file URL in the drag payload (non-file URLs are never accepted)
    func droppedURL(from sender: any NSDraggingInfo) -> URL? {
        fileURL(on: sender.draggingPasteboard)
    }

    private func fileURL(on pasteboard: NSPasteboard) -> URL? {
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true])
        return objects?.first as? URL
    }

    // MARK: Focus-loss reset (after clearing by delete, clicking elsewhere, switching apps; never leaves a blank address bar)

    func controlTextDidEndEditing(_ notification: Notification) {
        // The onCommit / onRevealFile / onCancel paths hide the field before moving firstResponder,
        // so isHidden is already true here: skip, to avoid resetting twice.
        // Only focus loss from "user clicked elsewhere / tabbed away / window deactivated" (field still visible) needs a reset.
        guard !isHidden else { return }
        // Must defer to the next runloop: changing firstResponder on this callback stack reenters AppKit's end-editing transaction.
        // Tests show that reentry disturbs window/focus timing and sends the next "external open" to the wrong window (I-52 failed deterministically from this).
        // Same pattern as the deferred complete(nil) in controlTextDidChange (I-30).
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isHidden else { return }
            // Focus back in the address bar = not "the user left" at all. Typical case: pressing ⌘L again while editing; beginEditing resetting
            // stringValue makes AppKit end the prior edit and call back here, and a normal reset would close the address bar in use.
            // currentEditor() non-nil means "this control is being edited", the most direct test for this.
            if self.currentEditor() != nil { return }
            if self.rejectedJustNow {
                // End of editing caused by a bad path: give focus back and select all so the user can retype, rather than kicking them out
                self.rejectedJustNow = false
                self.window?.makeFirstResponder(self)
                self.currentEditor()?.selectAll(nil)
                return
            }
            // Tell two kinds of "end editing" apart:
            //   · focus lands on another control in this window = the user clicked elsewhere inside it and really gave up editing -> reset (the bug#3 path)
            //   · the whole app/window deactivated (⌘Tab away / ⌘H hide / ⌘M minimize): AppKit takes firstResponder back to
            //       the window itself (not any NSView). That is not giving up; a normal reset would throw away a half-typed
            //       or pasted-but-uncommitted path with the editing state. Safari/Chrome keep the content on return, and this matches them.
            let responder = self.window?.firstResponder as? NSView
            let movedWithinWindow = responder != nil && responder !== self && responder?.window === self.window
            guard NSApp.isActive || movedWithinWindow else { return }
            self.onReset?()
        }
    }

    /// Invalid path in-place feedback: shake + beep + inline red text in the address bar (no alerts: spec craftsmanship invariant)
    private func reject(_ message: String) {
        rejectedJustNow = true
        shake()
        onInvalid?(message)
    }

    private func shake() {
        NSSound.beep()
        guard let layer else { return }
        // The base must be the layer's current position.x, not frame.midX: AppKit layer-backed views have
        // anchorPoint (0,0), so layer.position equals the frame origin, not the center. Basing on midX makes
        // the address bar "teleport" half its own width and bounce back, looking like a glitch rather than a shake.
        let baseX = layer.position.x
        let animation = CAKeyframeAnimation(keyPath: "position.x")
        animation.values = [0, -6, 6, -4, 4, 0].map { baseX + $0 }
        animation.duration = 0.3
        layer.add(animation, forKey: "shake")
    }

    /// UISelfTest (I-55): keyframes of the last shake animation (verifies the base is layer.position.x, not frame.midX)
    var uiTestShakeValues: [CGFloat] {
        (layer?.animation(forKey: "shake") as? CAKeyframeAnimation)?
            .values?.compactMap { ($0 as? NSNumber).map { CGFloat($0.doubleValue) } } ?? []
    }
}
