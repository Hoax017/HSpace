import AppKit
import FileHash
import HSpaceContracts

/// State of the file hash sheet, free of AppKit: the selected files, the algorithms, and what is known so far.
@MainActor
final class FileHashModel {
    enum Row {
        case waiting
        case done(FileDigest)
        case failed(String)
    }

    let files: [URL]
    private(set) var algorithms: Set<HashAlgorithm> = [.sha256]
    private(set) var rows: [URL: Row] = [:]
    private(set) var fraction = 0.0
    private(set) var isRunning = false
    private(set) var wasCancelled = false
    var expected = ""
    var onChange: (() -> Void)?

    init(files: [URL]) { self.files = files }

    func set(_ algorithm: HashAlgorithm, enabled: Bool) {
        if enabled { algorithms.insert(algorithm) } else { algorithms.remove(algorithm) }
    }

    /// Runs until done or until the calling task is cancelled. Finished rows stay.
    func run() async {
        guard !algorithms.isEmpty else { return }
        rows = [:]
        fraction = 0
        isRunning = true
        wasCancelled = false
        onChange?()
        do {
            for try await event in FileHasher.hash(files, algorithms: algorithms) {
                switch event {
                case .progress(let progress):
                    fraction = Double(progress.bytesDone) / Double(max(progress.bytesTotal, 1))
                case .finished(let outcome):
                    switch outcome.result {
                    case .success(let digest): rows[outcome.url] = .done(digest)
                    case .failure(let failure): rows[outcome.url] = .failed(failure.localizedDescription)
                    }
                }
                onChange?()
            }
        } catch {
            rows[files[0]] = .failed(error.localizedDescription)
        }
        wasCancelled = Task.isCancelled
        isRunning = false
        onChange?()
    }

    var digests: [FileDigest] {
        files.compactMap { if case .done(let digest) = rows[$0] { digest } else { nil } }
    }

    /// Against the pasted digest, if any: nil = nothing to compare.
    func matches(_ file: URL) -> Bool? {
        guard !expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              case .done(let digest) = rows[file] else { return nil }
        return FileHasher.match(expected, in: digest) != nil
    }

    var summary: String {
        if isRunning { return L10n.t("hash.running") }
        if wasCancelled { return L10n.t("hash.cancelled") }
        if algorithms.isEmpty { return L10n.t("hash.noAlgorithm") }
        let pasted = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pasted.isEmpty {
            if let algorithm = FileHasher.algorithm(of: pasted), !algorithms.contains(algorithm) {
                return L10n.f("hash.turnOn", algorithm.rawValue.uppercased())
            }
            let hits = files.filter { matches($0) == true }.count
            return hits > 0 ? L10n.f("hash.matches", hits) : L10n.t("hash.noMatch")
        }
        switch FileHasher.allIdentical(digests) {
        case true: return L10n.t("hash.identical")
        case false: return L10n.t("hash.different")
        default: return ""
        }
    }

    /// One "digest  name" line per file and algorithm, the format of the shasum tools.
    var copyText: String {
        files.flatMap { file -> [String] in
            guard case .done(let digest) = rows[file] else { return [] }
            return HashAlgorithm.allCases.compactMap { digest.values[$0] }.map { "\($0)  \(file.lastPathComponent)" }
        }.joined(separator: "\n")
    }

    func text(for file: URL, algorithm: HashAlgorithm) -> String {
        switch rows[file] {
        case .done(let digest): return digest.values[algorithm] ?? ""
        case .failed(let message): return message
        default: return ""
        }
    }
}

/// File hash: pick algorithms, watch the digests fill in, paste one to compare, copy the result. Nothing is written.
@MainActor
final class FileHashSheetController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private static var live: FileHashSheetController?

    let model: FileHashModel
    private let host: NSWindow
    private let panel = ToolUI.panel(width: 720, height: 440)
    private var table: NSTableView!
    private let summary = ToolUI.label()
    private let bar = ToolUI.progressBar()
    private lazy var expectedField = ToolUI.field(placeholder: L10n.t("hash.expected"), delegate: self)
    private lazy var actionButton = ToolUI.button(L10n.t("common.close"), target: self, action: #selector(closeOrCancel))
    private lazy var runButton = ToolUI.button(L10n.t("hash.run"), target: self, action: #selector(start))
    private lazy var copyButton = ToolUI.button(L10n.t("hash.copy"), target: self, action: #selector(copyDigests))
    private var checks: [HashAlgorithm: NSButton] = [:]
    private var work: Task<Void, Never>?

    static func present(files: [URL], in host: NSWindow) {
        guard live == nil, host.attachedSheet == nil else { return }
        let sheet = FileHashSheetController(files: files, host: host)
        live = sheet
        host.beginSheet(sheet.panel) { _ in }
        sheet.start()
    }

    init(files: [URL], host: NSWindow) {
        model = FileHashModel(files: files)
        self.host = host
        super.init()

        let boxes = HashAlgorithm.allCases.map { algorithm -> NSButton in
            let check = ToolUI.check(algorithm.rawValue.uppercased(), target: self, action: #selector(algorithmChanged(_:)))
            check.state = model.algorithms.contains(algorithm) ? .on : .off
            checks[algorithm] = check
            return check
        }
        let options = ToolUI.buttonRow(leading: ToolUI.title(L10n.f("hash.title", files.count)), boxes + [runButton])
        let (scroll, table) = ToolUI.table(columns: [("name", L10n.t("hash.column.file"), 200)] + HashAlgorithm.allCases.map {
            ($0.rawValue, $0.rawValue.uppercased(), 150)
        }, source: self, height: 240)
        self.table = table
        actionButton.keyEquivalent = "\u{1b}"
        ToolUI.fill(panel, with: [
            options, scroll, expectedField, bar,
            ToolUI.buttonRow(leading: summary, [copyButton, actionButton]),
        ])
        model.onChange = { [weak self] in self?.modelChanged() }
        modelChanged()
    }

    private func modelChanged() {
        table.reloadData()
        bar.isHidden = !model.isRunning
        bar.doubleValue = model.fraction
        summary.stringValue = model.summary
        actionButton.title = L10n.t(model.isRunning ? "common.cancel" : "common.close")
        runButton.isEnabled = !model.isRunning && !model.algorithms.isEmpty
        copyButton.isEnabled = !model.copyText.isEmpty
        checks.values.forEach { $0.isEnabled = !model.isRunning }
    }

    @objc private func algorithmChanged(_ sender: NSButton) {
        guard let algorithm = checks.first(where: { $0.value === sender })?.key else { return }
        model.set(algorithm, enabled: sender.state == .on)
        modelChanged()
    }

    @objc private func start() {
        guard !model.isRunning else { return }
        work = Task { [model] in await model.run() }
    }

    @objc private func closeOrCancel() {
        if model.isRunning {
            work?.cancel()
        } else {
            host.endSheet(panel)
            panel.orderOut(nil)
            Self.live = nil
        }
    }

    @objc private func copyDigests() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.copyText, forType: .string)
        Toast.show(L10n.t("toast.hashCopied"), in: host)
    }

    func controlTextDidChange(_ notification: Notification) {
        model.expected = expectedField.stringValue
        modelChanged()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { model.files.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let file = model.files[row]
        guard let id = tableColumn?.identifier.rawValue else { return nil }
        guard let algorithm = HashAlgorithm(rawValue: id) else {
            return ToolUI.cell(in: tableView, text: file.lastPathComponent)
        }
        var color = NSColor.labelColor
        if case .failed = model.rows[file] { color = .systemRed }
        let text = model.text(for: file, algorithm: algorithm)
        if model.matches(file) == true, FileHasher.match(model.expected, in: FileDigest(byteCount: 0, values: [algorithm: text])) != nil {
            color = .systemGreen
        }
        return ToolUI.cell(in: tableView, text: text, color: color)
    }
}
