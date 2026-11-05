import AppKit
import UniformTypeIdentifiers
import FileMetadata

/// The choices in the folder icon sheet. Pure, so what they turn into is tested without a window.
struct FolderIconChoice: Equatable {
    var color: FileColor?
    var emojiText = ""
    /// Show the emoji without the folder behind it
    var emojiAlone = false
    var imageFile: URL?

    /// nil while nothing is chosen. A chosen picture wins, because it takes the whole icon.
    var spec: FolderIconSpec? {
        if let imageFile { return .image(imageFile) }
        let emoji = FolderIconRenderer.singleEmoji(in: emojiText)
        if let emoji, emojiAlone { return .emoji(emoji) }
        guard color != nil || emoji != nil else { return nil }
        return .styled(color: color, emoji: emoji)
    }
}

/// Sheet to pick a colour, an emoji or a picture, with a live preview.
@MainActor
final class FolderIconSheet: NSObject, NSTextFieldDelegate {
    private var choice = FolderIconChoice()
    private let onApply: (FolderIconSpec) -> Void
    private let sheet: NSWindow
    private let preview = NSImageView()
    private let colorPopup = NSPopUpButton()
    private let emojiField = NSTextField()
    private let aloneBox = NSButton(checkboxWithTitle: L10n.t("folderIcon.emojiAlone"), target: nil, action: nil)
    private let imageLabel = NSTextField(labelWithString: "")
    private let apply = NSButton()
    private static var open: FolderIconSheet?

    private init(title: String, onApply: @escaping (FolderIconSpec) -> Void) {
        self.onApply = onApply
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
                         styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        buildContent(title: title)
        refresh()
    }

    static func present(title: String, in window: NSWindow, onApply: @escaping (FolderIconSpec) -> Void) {
        let picker = FolderIconSheet(title: title, onApply: onApply)
        open = picker
        window.beginSheet(picker.sheet) { _ in
            MainActor.assumeIsolated { open = nil }
        }
    }

    private func buildContent(title: String) {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13)
        heading.lineBreakMode = .byTruncatingMiddle

        colorPopup.addItem(withTitle: L10n.t("fileColor.none"))
        for color in FileColor.allCases {
            colorPopup.addItem(withTitle: FileColorPalette.name(color))
            colorPopup.lastItem?.image = FileColorPalette.menuImage(color)
            colorPopup.lastItem?.representedObject = color.rawValue
        }
        colorPopup.target = self
        colorPopup.action = #selector(colorChanged(_:))
        colorPopup.setAccessibilityLabel(L10n.t("folderIcon.color"))

        emojiField.delegate = self
        emojiField.placeholderString = L10n.t("folderIcon.emojiPlaceholder")
        emojiField.setAccessibilityLabel(L10n.t("folderIcon.emojiPlaceholder"))
        let palette = NSButton(title: L10n.t("folderIcon.showEmoji"), target: self, action: #selector(showEmoji(_:)))

        aloneBox.target = self
        aloneBox.action = #selector(aloneChanged(_:))

        let choose = NSButton(title: L10n.t("folderIcon.chooseImage"), target: self, action: #selector(chooseImage(_:)))
        imageLabel.font = .systemFont(ofSize: 11)
        imageLabel.textColor = .secondaryLabelColor
        imageLabel.lineBreakMode = .byTruncatingMiddle

        let colorRow = row(L10n.t("folderIcon.color"), [colorPopup])
        let emojiRow = row(L10n.t("folderIcon.emoji"), [emojiField, palette])
        let imageRow = row(L10n.t("folderIcon.image"), [choose, imageLabel])
        emojiField.widthAnchor.constraint(equalToConstant: 80).isActive = true

        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.setAccessibilityLabel(L10n.t("folderIcon.preview"))
        preview.translatesAutoresizingMaskIntoConstraints = false

        let controls = NSStackView(views: [colorRow, emojiRow, aloneBox, imageRow])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 8
        let body = NSStackView(views: [preview, controls])
        body.orientation = .horizontal
        body.alignment = .top
        body.spacing = 16

        let cancel = NSButton(title: L10n.t("common.cancel"), target: self, action: #selector(cancelClicked(_:)))
        cancel.keyEquivalent = "\u{1b}"
        apply.title = L10n.t("tags.picker.apply")
        apply.bezelStyle = .rounded
        apply.target = self
        apply.action = #selector(applyClicked(_:))
        apply.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, apply])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [heading, body, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            preview.widthAnchor.constraint(equalToConstant: 80),
            preview.heightAnchor.constraint(equalToConstant: 80),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -16),
            content.widthAnchor.constraint(equalToConstant: 400),
        ])
        sheet.contentView = content
    }

    private func row(_ title: String, _ views: [NSView]) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.widthAnchor.constraint(equalToConstant: 48).isActive = true
        let line = NSStackView(views: [label] + views)
        line.orientation = .horizontal
        line.spacing = 8
        return line
    }

    private func refresh() {
        let spec = choice.spec
        apply.isEnabled = spec != nil
        aloneBox.isEnabled = FolderIconRenderer.singleEmoji(in: choice.emojiText) != nil
        imageLabel.stringValue = choice.imageFile?.lastPathComponent ?? ""
        // A failed preview means no preview: Apply reports the real problem
        preview.image = spec.flatMap { try? FolderIconRenderer.render($0) }.flatMap(NSImage.init(data:))
    }

    @objc private func colorChanged(_ sender: NSPopUpButton) {
        let raw = sender.selectedItem?.representedObject as? String
        choice.color = raw.flatMap(FileColor.init(rawValue:))
        refresh()
    }

    func controlTextDidChange(_ obj: Notification) {
        choice.emojiText = emojiField.stringValue
        refresh()
    }

    @objc private func aloneChanged(_ sender: NSButton) {
        choice.emojiAlone = sender.state == .on
        refresh()
    }

    @objc private func showEmoji(_ sender: Any?) {
        sheet.makeFirstResponder(emojiField)
        NSApp.orderFrontCharacterPalette(sender)
    }

    @objc private func chooseImage(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK else { return }
        choice.imageFile = panel.url
        refresh()
    }

    @objc private func applyClicked(_ sender: Any?) {
        guard let spec = choice.spec else { return }
        close()
        onApply(spec)
    }

    @objc private func cancelClicked(_ sender: Any?) { close() }

    private func close() {
        sheet.sheetParent?.endSheet(sheet)
    }
}
