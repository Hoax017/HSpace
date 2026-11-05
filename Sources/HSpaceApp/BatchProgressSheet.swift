import AppKit

/// Progress and Cancel for work that does not go through the kernel, so it has no place in the progress window.
@MainActor
final class BatchProgressSheet: NSObject {
    var onCancel: (() -> Void)?

    private let sheet: NSWindow
    private let bar = NSProgressIndicator()
    private let counter = NSTextField(labelWithString: "")
    private let total: Int

    init(title: String, total: Int) {
        self.total = total
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 112),
                         styleMask: [.titled], backing: .buffered, defer: true)
        super.init()
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13)
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = Double(max(total, 1))
        bar.setAccessibilityLabel(title)
        counter.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        counter.textColor = .secondaryLabelColor
        let cancel = NSButton(title: L10n.t("common.cancel"), target: self, action: #selector(cancelClicked(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let stack = NSStackView(views: [heading, bar, counter, cancel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            content.widthAnchor.constraint(equalToConstant: 320),
            bar.widthAnchor.constraint(equalToConstant: 288),
        ])
        sheet.contentView = content
        update(done: 0)
    }

    func show(in window: NSWindow?) {
        guard let window, window.attachedSheet == nil else { return }
        window.beginSheet(sheet)
    }

    func update(done: Int) {
        bar.doubleValue = Double(done)
        counter.stringValue = L10n.f("batch.progress", done, total)
    }

    func close() {
        sheet.sheetParent?.endSheet(sheet)
    }

    @objc private func cancelClicked(_ sender: Any?) {
        onCancel?()
    }
}
