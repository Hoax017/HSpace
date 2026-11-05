import AppKit

/// What the comment editor starts from. When the items disagree it starts empty and says so, because one comment
/// picked at random would look like the comment of them all.
struct CommentEditStart: Equatable {
    let text: String
    let differs: Bool

    init(comments: [String]) {
        let distinct = Set(comments)
        differs = distinct.count > 1
        text = differs ? "" : (distinct.first ?? "")
    }
}

/// Sheet with a text box. Return makes a new line, as in Finder's comment box; ⌘Return saves.
@MainActor
final class CommentSheet: NSObject {
    private let onSave: (String) -> Void
    private let sheet: NSWindow
    private let text = NSTextView()
    private static var open: CommentSheet?

    private init(start: CommentEditStart, title: String, onSave: @escaping (String) -> Void) {
        self.onSave = onSave
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                         styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        buildContent(start: start, title: title)
    }

    static func present(start: CommentEditStart, title: String, in window: NSWindow,
                        onSave: @escaping (String) -> Void) {
        let editor = CommentSheet(start: start, title: title, onSave: onSave)
        open = editor
        window.beginSheet(editor.sheet) { _ in
            MainActor.assumeIsolated { open = nil }
        }
        editor.sheet.makeFirstResponder(editor.text)
    }

    private func buildContent(start: CommentEditStart, title: String) {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13)
        heading.lineBreakMode = .byTruncatingMiddle

        text.string = start.text
        text.font = .systemFont(ofSize: 12)
        text.isRichText = false
        text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.setAccessibilityLabel(title)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder

        let cancel = NSButton(title: L10n.t("common.cancel"), target: self, action: #selector(cancelClicked(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: L10n.t("comment.save"), target: self, action: #selector(saveClicked(_:)))
        save.keyEquivalent = "\r"
        save.keyEquivalentModifierMask = .command
        let buttons = NSStackView(views: [NSView(), cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        var views: [NSView] = [heading]
        if start.differs {
            let note = NSTextField(wrappingLabelWithString: L10n.t("comment.differs"))
            note.font = .systemFont(ofSize: 11)
            note.textColor = .secondaryLabelColor
            views.append(note)
        }
        views += [scroll, buttons]
        let stack = NSStackView(views: views)
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
            scroll.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -16),
            scroll.heightAnchor.constraint(equalToConstant: 112),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -16),
            content.widthAnchor.constraint(equalToConstant: 400),
        ])
        sheet.contentView = content
    }

    @objc private func saveClicked(_ sender: Any?) {
        let value = text.string
        close()
        onSave(value)
    }

    @objc private func cancelClicked(_ sender: Any?) { close() }

    private func close() {
        sheet.sheetParent?.endSheet(sheet)
    }
}
