import AppKit
import HSpaceContracts
import ImageConvert
import UniformTypeIdentifiers

/// State of the image conversion sheet, free of AppKit.
@MainActor
final class ImageConvertModel {
    enum ResizeMode: Int, CaseIterable {
        case original, percent, longestSide
    }

    let sources: [URL]
    /// Formats offered, in menu order, after "Keep format"
    let formats = ImageFormat.allCases.filter(\.isWritable)
    /// 0 keeps each image's format, the rest index `formats`
    var formatIndex = 0
    var quality = 0.85
    var resizeMode = ResizeMode.original
    var resizeValue = ""
    var keepMetadata = true
    var destination: URL?
    private(set) var fraction = 0.0
    private(set) var outputs: [URL] = []
    private(set) var failures: [String] = []
    private(set) var isRunning = false
    private var cancellation = ImageConvertCancel()
    var onChange: (() -> Void)?

    init(sources: [URL]) { self.sources = sources }

    var format: ImageFormat? { formatIndex == 0 ? nil : formats[safe: formatIndex - 1] }

    /// nil = the typed size is not usable yet
    var resize: ImageResize? {
        guard resizeMode != .original else { return .original }
        guard let value = Int(resizeValue.trimmingCharacters(in: .whitespaces)), value > 0 else { return nil }
        switch resizeMode {
        case .percent: return value <= 100 ? .percent(value) : nil
        default: return .longestSide(value)
        }
    }

    var options: ImageConvertOptions? {
        resize.map { ImageConvertOptions(format: format, quality: quality, resize: $0, keepMetadata: keepMetadata, destination: destination) }
    }

    /// Stops before the next image. `run` returns once the image in hand has landed.
    func cancel() { cancellation.cancel() }

    func run() async {
        guard let options else { return }
        cancellation = ImageConvertCancel()
        isRunning = true
        fraction = 0
        outputs = []
        failures = []
        onChange?()
        do {
            for try await event in ImageConverter.convert(sources, options: options, cancel: cancellation) {
                switch event {
                case .progress(let done, let total, _):
                    fraction = Double(done) / Double(max(total, 1))
                case .finished(let outcome):
                    switch outcome.result {
                    case .success(let url): outputs.append(url)
                    case .failure(let failure): failures.append(failure.localizedDescription)
                    }
                }
                onChange?()
            }
        } catch {
            failures.append(error.localizedDescription)
        }
        isRunning = false
        onChange?()
    }

    /// Whether an item is worth offering to the converter
    static func isImage(_ item: FileItem) -> Bool {
        guard !item.isDirectory, let id = item.contentTypeID, let type = UTType(id) else { return false }
        return type.conforms(to: .image)
    }
}

/// Image conversion: format, quality, size and where to write. The sources stay as they are; Undo moves the new files to the Trash.
@MainActor
final class ImageConvertSheetController: NSObject, NSTextFieldDelegate {
    private static var live: ImageConvertSheetController?

    let model: ImageConvertModel
    private let coordinator: FileOpsCoordinator
    private let host: NSWindow
    private let panel = ToolUI.panel(width: 480, height: 280)
    private lazy var formatPopup = ToolUI.popup([L10n.t("image.keepFormat")] + model.formats.map { $0.rawValue.uppercased() },
                                                label: L10n.t("image.format"), target: self, action: #selector(optionsChanged))
    private lazy var resizePopup = ToolUI.popup(["image.size.original", "image.size.percent", "image.size.longest"].map { L10n.t($0) },
                                                label: L10n.t("image.size"), target: self, action: #selector(optionsChanged))
    private lazy var sizeField = ToolUI.field(placeholder: L10n.t("image.sizeValue"), delegate: self)
    private lazy var quality = NSSlider(value: model.quality, minValue: 0, maxValue: 1, target: self, action: #selector(optionsChanged))
    private lazy var metadata = ToolUI.check(L10n.t("image.keepMetadata"), target: self, action: #selector(optionsChanged))
    private lazy var destinationLabel = ToolUI.label(L10n.t("image.nextToOriginals"))
    private lazy var chooseButton = ToolUI.button(L10n.t("image.choose"), target: self, action: #selector(chooseDestination))
    private lazy var cancelButton = ToolUI.button(L10n.t("common.cancel"), target: self, action: #selector(cancelTapped))
    private lazy var convertButton = ToolUI.button(L10n.t("image.convert"), target: self, action: #selector(convertTapped))
    private let bar = ToolUI.progressBar()
    private var work: Task<Void, Never>?

    static func present(sources: [URL], coordinator: FileOpsCoordinator, in host: NSWindow) {
        guard live == nil, host.attachedSheet == nil else { return }
        let sheet = ImageConvertSheetController(sources: sources, coordinator: coordinator, host: host)
        live = sheet
        host.beginSheet(sheet.panel) { _ in }
    }

    init(sources: [URL], coordinator: FileOpsCoordinator, host: NSWindow) {
        model = ImageConvertModel(sources: sources)
        self.coordinator = coordinator
        self.host = host
        super.init()

        formatPopup.selectItem(at: model.formatIndex)
        metadata.state = model.keepMetadata ? .on : .off
        quality.controlSize = .small
        quality.setAccessibilityLabel(L10n.t("image.quality"))
        sizeField.widthAnchor.constraint(equalToConstant: 72).isActive = true

        func row(_ title: String, _ views: [NSView]) -> NSStackView {
            let label = ToolUI.label(title)
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 72).isActive = true
            let stack = NSStackView(views: [label] + views)
            stack.orientation = .horizontal
            stack.spacing = 8
            return stack
        }
        cancelButton.keyEquivalent = "\u{1b}"
        convertButton.keyEquivalent = "\r"
        ToolUI.fill(panel, with: [
            ToolUI.title(L10n.f("image.title", sources.count)),
            row(L10n.t("image.format"), [formatPopup]),
            row(L10n.t("image.quality"), [quality]),
            row(L10n.t("image.size"), [resizePopup, sizeField]),
            row(L10n.t("image.destination"), [destinationLabel, chooseButton]),
            metadata,
            bar,
            ToolUI.buttonRow([cancelButton, convertButton]),
        ])
        model.onChange = { [weak self] in self?.modelChanged() }
        modelChanged()
    }

    private func modelChanged() {
        bar.isHidden = !model.isRunning
        bar.doubleValue = model.fraction
        sizeField.isEnabled = model.resizeMode != .original
        sizeField.placeholderString = L10n.t(model.resizeMode == .percent ? "image.sizeValue.percent" : "image.sizeValue")
        quality.isEnabled = model.format == .jpeg || model.format == .heic || model.format == nil
        convertButton.isEnabled = model.options != nil && !model.isRunning
        destinationLabel.stringValue = model.destination?.lastPathComponent ?? L10n.t("image.nextToOriginals")
    }

    @objc private func optionsChanged() {
        model.formatIndex = formatPopup.indexOfSelectedItem
        model.quality = quality.doubleValue
        model.resizeMode = ImageConvertModel.ResizeMode(rawValue: resizePopup.indexOfSelectedItem) ?? .original
        model.resizeValue = sizeField.stringValue
        model.keepMetadata = metadata.state == .on
        modelChanged()
    }

    func controlTextDidChange(_ notification: Notification) { optionsChanged() }

    @objc private func chooseDestination() {
        let open = NSOpenPanel()
        open.canChooseFiles = false
        open.canChooseDirectories = true
        open.canCreateDirectories = true
        open.prompt = L10n.t("image.choose")
        open.beginSheetModal(for: panel) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let self else { return }
                self.model.destination = open.url
                self.modelChanged()
            }
        }
    }

    @objc private func cancelTapped() {
        if model.isRunning {
            model.cancel()
        } else {
            close()
        }
    }

    @objc private func convertTapped() {
        guard !model.isRunning, model.options != nil else { return }
        work = Task { [weak self, model] in
            await model.run()
            self?.finish()
        }
    }

    private func finish() {
        work = nil
        close()
        coordinator.registerImageOutputUndo(model.outputs)
        coordinator.grid?.visiblePanes.forEach { $0.reloadActiveList() }
        if let first = model.failures.first {
            ToolUI.showError(L10n.f("image.partial", model.outputs.count, model.failures.count, first), in: host)
        } else {
            Toast.show(L10n.f("toast.convertedN", model.outputs.count), in: host)
        }
    }

    private func close() {
        host.endSheet(panel)
        panel.orderOut(nil)
        Self.live = nil
    }
}

extension FileOpsCoordinator {
    /// Undoing a conversion takes back only what it added, through the Trash, so even that can be undone.
    func registerImageOutputUndo(_ outputs: [URL]) {
        guard !outputs.isEmpty else { return }
        undoManager.registerUndo(withTarget: self) { coordinator in
            MainActor.assumeIsolated { coordinator.moveToTrash(outputs) }
        }
        undoManager.setActionName(L10n.t("undo.imageConvert"))
    }
}
