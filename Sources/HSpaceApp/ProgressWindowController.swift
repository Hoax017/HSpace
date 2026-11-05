import AppKit
import HSpaceKernel
import HSpaceContracts
import Scheduler

/// Task list (singleton): every unfinished operation, with its progress, queue state and controls.
/// Subscribes to kernel.projections() and the scheduler; nothing here polls.
/// orderFront only if not terminal after >0.5s; closes automatically 2s after everything is terminal, unless something failed: failed rows stay, with red text in place.
@MainActor
final class ProgressWindowController: NSWindowController {
    static let shared = ProgressWindowController()

    private var kernel: OperationKernel?
    private var scheduler: Scheduler?
    private var streamTask: Task<Void, Never>?
    private var scheduleTask: Task<Void, Never>?
    private var model = TaskListModel()
    private var rows: [UUID: ProgressRowView] = [:]
    private var rates: [UUID: (bytes: Int64, at: Date)] = [:]
    private let stack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: L10n.t("progress.empty"))
    private var pendingShow: Task<Void, Never>?
    private var pendingHide: Task<Void, Never>?
    private lazy var pauseAllButton = ToolUI.button(L10n.t("tasks.pauseAll"), target: self, action: #selector(togglePauseAll(_:)))
    private lazy var clearButton = ToolUI.button(L10n.t("tasks.clearFinished"), target: self, action: #selector(clearFinished(_:)))
    private lazy var limitPopup = ToolUI.popup(Self.limits.map { L10n.f("tasks.atOnce", $0) }, label: L10n.t("tasks.atOnceLabel"),
                                               target: self, action: #selector(limitChanged(_:)))

    private static let limits = [1, 2, 3, 4]

    private init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 240),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = L10n.t("progress.title")
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.contentMinSize = NSSize(width: 440, height: 160)
        super.init(window: panel)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let list = TaskListDocumentView()
        list.translatesAutoresizingMaskIntoConstraints = false
        list.addSubview(stack)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = list
        scroll.translatesAutoresizingMaskIntoConstraints = false

        for button in [pauseAllButton, clearButton] { button.controlSize = .small; button.font = .systemFont(ofSize: 11) }
        let footer = ToolUI.buttonRow(leading: limitPopup, [clearButton, pauseAllButton])
        footer.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        footer.translatesAutoresizingMaskIntoConstraints = false
        let hairline = NSBox()
        hairline.boxType = .separator
        hairline.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        for view in [scroll, hairline, footer] { content.addSubview(view) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            hairline.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            hairline.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.topAnchor.constraint(equalTo: hairline.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            list.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            list.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: list.topAnchor),
            stack.leadingAnchor.constraint(equalTo: list.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: list.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: list.bottomAnchor),
        ])
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        panel.contentView = content
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    /// Toolbar "task status" icon: manually toggles the task window
    @objc func toggleVisible(_ sender: Any?) {
        if window?.isVisible == true {
            window?.orderOut(nil)
        } else {
            refresh()
            window?.center()
            window?.makeKeyAndOrderFront(nil)
        }
    }

    func start(kernel: OperationKernel, scheduler: Scheduler) {
        guard streamTask == nil else { return }
        self.kernel = kernel
        self.scheduler = scheduler
        limitPopup.selectItem(at: Self.limits.firstIndex(of: Preferences.maxConcurrentOperations) ?? 1)
        streamTask = Task { [weak self] in
            guard let stream = await self?.kernel?.projections() else { return }
            for await p in stream {
                self?.apply(p)
            }
        }
        scheduleTask = Task { [weak self] in
            for await snapshot in scheduler.changes() {
                self?.apply(snapshot)
            }
        }
    }

    // MARK: Stream consumption

    private func apply(_ p: OperationProjection) {
        model.apply(p)
        if rows[p.id] == nil {
            let row = ProgressRowView(kind: p.kind)
            let id = p.id
            row.onCancel = { [weak self] in Task { await self?.kernel?.cancel(id) } }
            row.onPause = { [weak self] in self?.scheduler?.pause(id) }
            row.onResume = { [weak self] in self?.scheduler?.resume(id) }
            row.onPriority = { [weak self] in self?.scheduler?.setPriority($0, for: id) }
            rows[id] = row
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        latestRate[p.id] = rate(for: p)
        refresh()
        scheduleVisibility()
    }

    private func apply(_ snapshot: SchedulerSnapshot) {
        model.apply(snapshot)
        refresh()
    }

    private var latestRate: [UUID: Double] = [:]

    /// Brings the rows, their order, the footer and the toolbar in line with the model.
    private func refresh() {
        let entries = model.entries
        for entry in entries {
            guard let row = rows[entry.id], let projection = model.projections[entry.id] else { continue }
            row.update(projection, entry: entry, rate: latestRate[entry.id])
        }
        let ordered = entries.compactMap { rows[$0.id] }
        if stack.arrangedSubviews != ordered {
            for (index, row) in ordered.enumerated() { stack.insertArrangedSubview(row, at: index) }
        }
        emptyLabel.isHidden = !rows.isEmpty
        pauseAllButton.title = L10n.t(model.isQueuePaused ? "tasks.resumeAll" : "tasks.pauseAll")
        clearButton.isEnabled = entries.contains { $0.phase == .finished }
        NotificationCenter.default.post(name: .hspaceTaskStatusChanged, object: model.summary)
    }

    @objc private func togglePauseAll(_ sender: Any?) {
        guard let scheduler else { return }
        if scheduler.snapshot().isPaused { scheduler.resumeAll() } else { scheduler.pauseAll() }
    }

    @objc private func clearFinished(_ sender: Any?) {
        clear(keepingFailures: false)
    }

    @objc private func limitChanged(_ sender: NSPopUpButton) {
        let limit = Self.limits[sender.indexOfSelectedItem]
        Preferences.maxConcurrentOperations = limit
        scheduler?.setMaxConcurrent(limit)
    }

    /// Byte rate: byte delta / time delta between adjacent projections
    private func rate(for p: OperationProjection) -> Double? {
        let now = Date()
        defer { rates[p.id] = (p.bytesDone, now) }
        guard let prev = rates[p.id] else { return nil }
        let dt = now.timeIntervalSince(prev.at)
        guard dt > 0.01, p.bytesDone >= prev.bytes else { return nil }
        return Double(p.bytesDone - prev.bytes) / dt
    }

    // MARK: Visibility timing (show after >0.5s; close 2s after all terminal)

    private func scheduleVisibility() {
        if model.hasUnfinished {
            pendingHide?.cancel(); pendingHide = nil
            if window?.isVisible != true, pendingShow == nil {
                pendingShow = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard let self, !Task.isCancelled, self.model.hasUnfinished else { self?.pendingShow = nil; return }
                    self.window?.center()
                    self.window?.orderFront(nil)
                    self.pendingShow = nil
                }
            }
        } else {
            pendingShow?.cancel(); pendingShow = nil
            // All terminal: clear accumulated rows whether or not the window is showing (a hidden window must recycle them too)
            if !rows.isEmpty, pendingHide == nil {
                pendingHide = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard let self, !Task.isCancelled, !self.model.hasUnfinished else { self?.pendingHide = nil; return }
                    if self.window?.isVisible == true, !self.model.hasFailures { self.window?.orderOut(nil) }
                    self.clear(keepingFailures: true)
                    self.pendingHide = nil
                }
            }
        }
    }

    private func clear(keepingFailures: Bool) {
        for id in model.clearFinished(keepingFailures: keepingFailures) {
            rows.removeValue(forKey: id)?.removeFromSuperview()
            rates[id] = nil
            latestRate[id] = nil
        }
        refresh()
    }
}

/// Grows downward from the top of the scroll view.
private final class TaskListDocumentView: NSView {
    override var isFlipped: Bool { true }
}

extension Notification.Name {
    /// Queue changed; the object is a `TaskStatusSummary`
    static let hspaceTaskStatusChanged = Notification.Name("hspaceTaskStatusChanged")
}

/// One operation row: kind icon + progress bar + current file + byte rate + pause, priority and cancel buttons; failures show red text in place
@MainActor
final class ProgressRowView: NSView {
    var onCancel: (() -> Void)?
    var onPause: (() -> Void)?
    var onResume: (() -> Void)?
    var onPriority: ((SchedulerPriority) -> Void)?
    private(set) var isTerminal = false

    private let icon = NSImageView()
    private let bar = NSProgressIndicator()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let cancelButton = NSButton()
    private let pauseButton = NSButton()
    private let priorityButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private var isPaused = false

    init(kind: OperationSpec.Kind) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        icon.image = NSImage(systemSymbolName: Self.symbol(kind),
                             accessibilityDescription: nil)
        icon.contentTintColor = .controlAccentColor
        bar.isIndeterminate = false
        bar.minValue = 0; bar.maxValue = 1
        bar.controlSize = .small
        title.font = .systemFont(ofSize: 11)
        title.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        cancelButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L10n.t("progress.cancel"))
        cancelButton.isBordered = false
        cancelButton.bezelStyle = .inline
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.toolTip = L10n.t("progress.cancel")
        pauseButton.isBordered = false
        pauseButton.bezelStyle = .inline
        pauseButton.target = self
        pauseButton.action = #selector(pauseTapped)
        buildPriorityMenu()

        for v in [icon, bar, title, detail, cancelButton, pauseButton, priorityButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.topAnchor.constraint(equalTo: topAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            cancelButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            cancelButton.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: 20),
            bar.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            pauseButton.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -4),
            pauseButton.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            pauseButton.widthAnchor.constraint(equalToConstant: 20),
            priorityButton.trailingAnchor.constraint(equalTo: pauseButton.leadingAnchor, constant: -4),
            priorityButton.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            priorityButton.widthAnchor.constraint(equalToConstant: 28),
            bar.trailingAnchor.constraint(equalTo: priorityButton.leadingAnchor, constant: -8),
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            title.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            title.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 2),
            detail.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            detail.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    @objc private func cancelTapped() { onCancel?() }

    @objc private func pauseTapped() {
        if isPaused { onResume?() } else { onPause?() }
    }

    /// A pull-down whose first item is its face: an icon, not the current choice.
    private func buildPriorityMenu() {
        let label = L10n.t("tasks.priority")
        priorityButton.isBordered = false
        priorityButton.toolTip = label
        priorityButton.setAccessibilityLabel(label)
        let face = NSMenuItem()
        face.image = NSImage.officialSymbol("flag", accessibility: label)
        priorityButton.menu?.addItem(face)
        for priority in SchedulerPriority.allCases.reversed() {
            let item = NSMenuItem(title: L10n.t("tasks.priority.\(priority)"), action: #selector(priorityPicked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = priority.rawValue
            priorityButton.menu?.addItem(item)
        }
    }

    @objc private func priorityPicked(_ sender: NSMenuItem) {
        guard let priority = SchedulerPriority(rawValue: sender.tag) else { return }
        onPriority?(priority)
    }

    func update(_ p: OperationProjection, entry: TaskEntry, rate: Double?) {
        isTerminal = p.state.isTerminal
        if p.bytesTotal > 0 {
            bar.isIndeterminate = false
            bar.doubleValue = min(1, Double(p.bytesDone) / Double(p.bytesTotal))
        } else if entry.phase == .active {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
        } else {
            bar.stopAnimation(nil)
            bar.isIndeterminate = false
        }
        updateControls(entry)

        switch p.state {
        case .failed(let message, _):
            bar.stopAnimation(nil)
            title.stringValue = message
            title.textColor = .systemRed
            detail.stringValue = ""
        case .completed:
            bar.stopAnimation(nil)
            bar.isIndeterminate = false
            bar.doubleValue = 1
            title.stringValue = (p.currentPath as NSString?)?.lastPathComponent ?? ""
            title.textColor = .labelColor
            detail.stringValue = L10n.t("progress.done")
        case .cancelled:
            bar.stopAnimation(nil)
            title.stringValue = L10n.t("progress.cancelled")
            title.textColor = .secondaryLabelColor
            detail.stringValue = ""
        default:
            title.textColor = .labelColor
            title.stringValue = (p.currentPath as NSString?)?.lastPathComponent ?? Self.name(of: p)
            detail.stringValue = detailText(p, phase: entry.phase, rate: rate)
        }
    }

    private func updateControls(_ entry: TaskEntry) {
        isPaused = entry.phase == .paused
        cancelButton.isHidden = entry.phase == .finished
        pauseButton.isHidden = !entry.canPause
        let key = isPaused ? "tasks.resume" : "tasks.pause"
        pauseButton.image = NSImage.officialSymbol(isPaused ? "play.circle" : "pause.circle", accessibility: L10n.t(key))
        pauseButton.toolTip = L10n.t(key)
        pauseButton.setAccessibilityLabel(L10n.t(key))
        priorityButton.isHidden = entry.priority == nil || entry.phase == .active
        for item in priorityButton.itemArray.dropFirst() {
            item.state = item.tag == entry.priority?.rawValue ? .on : .off
        }
    }

    private func detailText(_ p: OperationProjection, phase: TaskPhase, rate: Double?) -> String {
        switch phase {
        case .queued: return L10n.t("tasks.queued")
        case .waitingForPath: return L10n.t("tasks.waitingForPath")
        case .paused: return L10n.t("tasks.paused")
        case .active, .finished: break
        }
        let counts = "\(p.filesDone)/\(max(p.filesTotal, p.filesDone))"
        let rateStr = rate.map { " · " + Formatters.size.string(fromByteCount: Int64($0)) + "/s" } ?? ""
        return counts + rateStr
    }

    /// The row's title before any file is under way
    private static func name(of p: OperationProjection) -> String {
        p.state == .pending ? L10n.t("tasks.kind.\(p.kind.rawValue)") : L10n.t("progress.preparing")
    }

    private static func symbol(_ kind: OperationSpec.Kind) -> String {
        switch kind {
        case .copy: "doc.on.doc"
        case .move: "arrow.right"
        case .trash: "trash"
        case .duplicate: "plus.square.on.square"
        case .rename: "pencil"
        case .newFolder: "folder.badge.plus"
        case .newFile: "doc.badge.plus"
        case .compress: "doc.zipper"
        case .extract: "arrow.up.bin"
        case .delete: "trash.slash"      // Permanent delete: slashed can, clearly distinct from "Move to Trash"
        }
    }
}
