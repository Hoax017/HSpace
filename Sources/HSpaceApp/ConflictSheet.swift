import AppKit
import HSpaceContracts

// MARK: - Decision state machine (pure-logic seam shared by the UI and UISelfTest; no AppKit dependency, can be asserted headless)

/// Decision state machine that advances conflict by conflict. With the checkbox on, it batches by "destination folder":
/// one decision applies to all unresolved conflicts in the current conflict's folder; other folders are decided separately (the panel reappears per folder).
struct ConflictDecisionMachine {
    let conflicts: [FileConflict]
    private(set) var decisions: [URL: ConflictDecision] = [:]
    private(set) var cancelled = false

    init(_ conflicts: [FileConflict]) { self.conflicts = conflicts }

    /// First conflict not yet decided (advances naturally after a decision; a batch skips the whole folder)
    var currentConflict: FileConflict? {
        cancelled ? nil : conflicts.first { decisions[$0.source] == nil }
    }
    var isComplete: Bool { cancelled || currentConflict == nil }
    /// nil = the user cancelled the whole operation (contract: ConflictArbiter returns nil)
    var result: [URL: ConflictDecision]? { cancelled ? nil : decisions }

    private func folderKey(_ c: FileConflict) -> String {
        c.existing.deletingLastPathComponent().standardizedFileURL.path
    }

    /// Decides only the current conflict (checkbox off)
    mutating func decideCurrent(_ d: ConflictDecision) {
        guard let c = currentConflict else { return }
        decisions[c.source] = d
    }

    /// Batch decision: all unresolved conflicts in the current conflict's folder get the same decision (checkbox on).
    /// The checkbox affects one folder at a time; multi-folder conflicts need several rounds (the panel reappears per folder).
    mutating func decideCurrentFolder(_ d: ConflictDecision) {
        guard let c = currentConflict else { return }
        let key = folderKey(c)
        for x in conflicts where decisions[x.source] == nil && folderKey(x) == key {
            decisions[x.source] = d
        }
    }

    mutating func cancel() { cancelled = true }
}

// MARK: - Conflict Arbiter (the kernel uses it to show a custom sheet in place on the active window)

/// Stateless → thread-safe (@unchecked Sendable; touches UI only on the MainActor).
final class ConflictSheet: ConflictArbiter, @unchecked Sendable {
    func arbitrate(operation id: UUID, conflicts: [FileConflict]) async -> [URL: ConflictDecision]? {
        await withCheckedContinuation { (cont: CheckedContinuation<[URL: ConflictDecision]?, Never>) in
            Task { @MainActor in
                ConflictSheetController.present(conflicts) { cont.resume(returning: $0) }
            }
        }
    }

    // MARK: UISelfTest headless seam (never shows a real modal, which would hang the watchdog; only drives the state machine to verify batching/advancing/cancelling)

    /// Drives the state machine action by action and returns the final decisions; actions: ("item", d) decide current / ("folder", d) batch this folder / ("cancel", _)
    @MainActor
    static func uiTestResolve(_ conflicts: [FileConflict],
                              actions: [(String, ConflictDecision?)]) -> [URL: ConflictDecision]? {
        var m = ConflictDecisionMachine(conflicts)
        for (kind, decision) in actions where !m.isComplete {
            switch kind {
            case "item":   if let d = decision { m.decideCurrent(d) }
            case "folder": if let d = decision { m.decideCurrentFolder(d) }
            case "cancel": m.cancel()
            default: break
            }
        }
        return m.result
    }

    /// Number of panel appearances (= folders the user must decide in turn, checkbox case): batches folder by folder until all are decided.
    @MainActor
    static func uiTestFolderPromptCount(_ conflicts: [FileConflict], batchDecision: ConflictDecision) -> Int {
        var m = ConflictDecisionMachine(conflicts)
        var prompts = 0
        while !m.isComplete { prompts += 1; m.decideCurrentFolder(batchDecision) }
        return prompts
    }

    /// Builds and configures the first conflict's panel without a modal, for screenshots/assertions (final human review of the custom layout; no beginSheet, no modal)
    @MainActor
    static func uiTestPanel(_ conflicts: [FileConflict], host: NSWindow) -> NSWindow? {
        ConflictSheetController.uiTestPanel(conflicts, host: host)
    }
}

// MARK: - Custom sheet controller (three right-aligned buttons Cancel/Merge/Replace + bottom-left "Apply to this folder" checkbox; QSpace look)

@MainActor
private final class ConflictSheetController: NSObject {
    private static var live: ConflictSheetController?   // Lifetime anchor (holds itself while the sheet is alive)

    private let panel: NSPanel
    private let hostWindow: NSWindow
    private var machine: ConflictDecisionMachine
    private let completion: ([URL: ConflictDecision]?) -> Void

    // Content controls (reconfigured for each conflict)
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private let srcIcon = NSImageView()
    private let srcLabel = NSTextField(labelWithString: "")
    private let dstIcon = NSImageView()
    private let dstLabel = NSTextField(labelWithString: "")
    private let applyFolderCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var mergeButton: NSButton?
    private var keepBothButton: NSButton?

    static func present(_ conflicts: [FileConflict],
                        completion: @escaping ([URL: ConflictDecision]?) -> Void) {
        guard let host = NSApp.keyWindow ?? NSApp.mainWindow, !conflicts.isEmpty else {
            completion(conflicts.isEmpty ? [:] : nil); return
        }
        let c = ConflictSheetController(conflicts: conflicts, host: host, completion: completion)
        live = c
        c.start()
    }

    private init(conflicts: [FileConflict], host: NSWindow,
                 completion: @escaping ([URL: ConflictDecision]?) -> Void) {
        self.hostWindow = host
        self.machine = ConflictDecisionMachine(conflicts)
        self.completion = completion
        self.panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 224),
                             styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        buildContent()
    }

    private func start() {
        guard let conflict = machine.currentConflict else { finish(machine.result); return }
        configure(for: conflict)
        hostWindow.beginSheet(panel) { _ in }   // Decisions go through button actions to finish(endSheet); this callback carries no result
    }

    /// UISelfTest: builds and configures the first conflict without a modal, returning the panel window for screenshots/assertions (no beginSheet, no live)
    static func uiTestPanel(_ conflicts: [FileConflict], host: NSWindow) -> NSWindow? {
        guard let first = conflicts.first else { return nil }
        let c = ConflictSheetController(conflicts: conflicts, host: host, completion: { _ in })
        c.configure(for: first)
        c.panel.layoutIfNeeded()
        return c.panel
    }

    // MARK: Per-conflict reconfiguration

    private func configure(for conflict: FileConflict) {
        titleLabel.stringValue = L10n.f("conflict.title", conflict.existing.lastPathComponent)
        messageLabel.stringValue = L10n.t("conflict.message")
        configureRow(icon: srcIcon, label: srcLabel, title: L10n.t("conflict.source"), url: conflict.source)
        configureRow(icon: dstIcon, label: dstLabel, title: L10n.t("conflict.existing"), url: conflict.existing)
        // Merging only makes sense when both sides are directories; disabled for file conflicts (keeps the button layout stable; disabled is honestly unclickable)
        mergeButton?.isEnabled = conflict.bothDirectories
        keepBothButton?.isEnabled = true   // Files and folders can both be renamed to coexist
        // Reset the checkbox each time the panel appears (per folder): checking it is an explicit batch choice for "this folder, this time"
        applyFolderCheck.state = .off
    }

    private func configureRow(icon: NSImageView, label: NSTextField, title: String, url: URL) {
        icon.image = NSWorkspace.shared.icon(forFile: url.path)
        icon.image?.size = NSSize(width: 20, height: 20)
        let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey])
        let sizeStr: String = (vals?.isDirectory == true)
            ? "—" : (vals?.fileSize).map { Formatters.size.string(fromByteCount: Int64($0)) } ?? "—"
        let dateStr = vals?.contentModificationDate.map { Formatters.relativeDate($0) } ?? "—"
        label.stringValue = "\(title)   \(dateStr) · \(sizeStr)"
    }

    // MARK: Actions (checkbox on → batch this folder; otherwise decide only the current one)

    @objc private func onReplace() { apply(.replace) }
    @objc private func onMerge() { apply(.mergeFolders) }
    /// Keep Both: auto-rename so both coexist (`file 2.txt`). The engine's `.keepBoth` has long existed
    /// (including de-duplication of collisions within a batch); the old version just had no button. User report: "only Merge and Cancel, no rename".
    @objc private func onKeepBoth() { apply(.keepBoth) }
    @objc private func onCancel() { machine.cancel(); finish(nil) }

    private func apply(_ d: ConflictDecision) {
        if applyFolderCheck.state == .on { machine.decideCurrentFolder(d) } else { machine.decideCurrent(d) }
        if let next = machine.currentConflict { configure(for: next) } else { finish(machine.result) }
    }

    private func finish(_ decisions: [URL: ConflictDecision]?) {
        hostWindow.endSheet(panel)
        panel.orderOut(nil)
        completion(decisions)
        ConflictSheetController.live = nil
    }

    // MARK: Layout construction (4pt grid; three right-aligned buttons + bottom-left checkbox)

    private func buildContent() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 224))

        titleLabel.font = .boldSystemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        messageLabel.font = .systemFont(ofSize: 11)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 2

        for lb in [srcLabel, dstLabel] {
            lb.font = .systemFont(ofSize: 11)
            lb.textColor = .secondaryLabelColor
            lb.lineBreakMode = .byTruncatingMiddle
        }

        applyFolderCheck.title = L10n.t("conflict.applyFolder")
        applyFolderCheck.font = .systemFont(ofSize: 11)

        // Four buttons: Cancel / Merge / Keep Both / Replace (right-aligned). Return = Keep Both, never Replace:
        // a stray Return must not overwrite anything, and Keep Both is the one choice that is always enabled and loses no data
        let cancelB = makeButton("conflict.cancel", #selector(onCancel)); cancelB.keyEquivalent = "\u{1b}"
        let mergeB = makeButton("conflict.merge", #selector(onMerge)); mergeButton = mergeB
        let keepBothB = makeButton("conflict.keepBoth", #selector(onKeepBoth)); keepBothButton = keepBothB
        keepBothB.keyEquivalent = "\r"
        let replaceB = makeButton("conflict.replace", #selector(onReplace))
        let buttonStack = NSStackView(views: [cancelB, mergeB, keepBothB, replaceB])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8

        for v in [titleLabel, messageLabel, srcIcon, srcLabel, dstIcon, dstLabel, applyFolderCheck, buttonStack] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }

        let pad: CGFloat = 20
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: pad),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            titleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),

            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            messageLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            messageLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),

            srcIcon.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 16),
            srcIcon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            srcIcon.widthAnchor.constraint(equalToConstant: 20),
            srcIcon.heightAnchor.constraint(equalToConstant: 20),
            srcLabel.centerYAnchor.constraint(equalTo: srcIcon.centerYAnchor),
            srcLabel.leadingAnchor.constraint(equalTo: srcIcon.trailingAnchor, constant: 8),
            srcLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),

            dstIcon.topAnchor.constraint(equalTo: srcIcon.bottomAnchor, constant: 8),
            dstIcon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            dstIcon.widthAnchor.constraint(equalToConstant: 20),
            dstIcon.heightAnchor.constraint(equalToConstant: 20),
            dstLabel.centerYAnchor.constraint(equalTo: dstIcon.centerYAnchor),
            dstLabel.leadingAnchor.constraint(equalTo: dstIcon.trailingAnchor, constant: 8),
            dstLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),

            applyFolderCheck.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            applyFolderCheck.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -pad),
            buttonStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),
            buttonStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -pad),
            buttonStack.leadingAnchor.constraint(greaterThanOrEqualTo: applyFolderCheck.trailingAnchor, constant: 12),
        ])
        panel.contentView = root
    }

    private func makeButton(_ key: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: L10n.t(key), target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }
}
