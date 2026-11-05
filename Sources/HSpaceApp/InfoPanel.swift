import AppKit
import UniformTypeIdentifiers
import FileMetadata

/// Get Info panel: icon / name / kind / size / path (selectable) / created and modified dates.
/// In-place, non-modal info panel; each call opens a separate NSPanel.
@MainActor
enum InfoPanel {
    private static var open: [NSPanel] = []

    static func show(for url: URL) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 300),
                            styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = L10n.f("info.title", url.lastPathComponent)
        panel.isReleasedWhenClosed = false
        panel.contentView = buildContent(for: url)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        open.append(panel)   // keeps it from being released; cleaned up on close
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: panel, queue: .main) { [weak panel] _ in
            MainActor.assumeIsolated {
                open.removeAll { $0 === panel }
            }
        }
    }

    private static func buildContent(for url: URL) -> NSView {
        let vals = try? url.resourceValues(forKeys: [
            .contentTypeKey, .fileSizeKey, .totalFileAllocatedSizeKey,
            .creationDateKey, .contentModificationDateKey, .isDirectoryKey,
        ])
        let isDir = vals?.isDirectory == true
        let kindStr = vals?.contentType?.localizedDescription
            ?? (isDir ? L10n.t("kind.folder") : L10n.t("kind.document"))
        let sizeStr = isDir
            ? "—"
            : (vals?.fileSize).map { Formatters.size.string(fromByteCount: Int64($0)) } ?? "—"
        let created = vals?.creationDate.map { Formatters.relativeDate($0) } ?? "—"
        let modified = vals?.contentModificationDate.map { Formatters.relativeDate($0) } ?? "—"

        let iconView = NSImageView()
        iconView.image = NSWorkspace.shared.icon(forFile: url.path)
        iconView.image?.size = NSSize(width: 64, height: 64)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: url.lastPathComponent)
        name.font = .boldSystemFont(ofSize: 13)
        name.alignment = .center
        name.lineBreakMode = .byTruncatingMiddle

        // Display only, so an unreadable item shows no tags and Get Info still opens
        let tags = (try? Engines.metadata.tags(of: url)) ?? []
        var rows = [
            row(L10n.t("info.kind"), kindStr),
            row(L10n.t("info.size"), sizeStr),
            row(L10n.t("info.created"), created),
            row(L10n.t("info.modified"), modified),
            row(L10n.t("info.path"), url.path, selectable: true),
        ]
        if !tags.isEmpty {
            rows.append(row(L10n.t("info.tags"), tags.map(\.name).joined(separator: ", ")))
        }
        if let comment = (try? Engines.metadata.comment(of: url)) ?? nil {
            rows.append(row(L10n.t("info.comment"), comment))
        }
        let fields = NSStackView(views: rows)
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 8
        fields.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        for v in [iconView, name, fields] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            iconView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),
            name.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 8),
            name.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            name.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            fields.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 16),
            fields.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            fields.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            fields.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -16),
        ])
        return container
    }

    private static func row(_ title: String, _ value: String, selectable: Bool = false) -> NSView {
        let key = NSTextField(labelWithString: title)
        key.font = .systemFont(ofSize: 11)
        key.textColor = .secondaryLabelColor
        key.setContentHuggingPriority(.required, for: .horizontal)

        let val = selectable
            ? NSTextField(string: value)
            : NSTextField(labelWithString: value)
        val.font = .systemFont(ofSize: 11)
        if selectable {
            val.isEditable = false
            val.isSelectable = true
            val.isBordered = false
            val.drawsBackground = false
        }
        val.lineBreakMode = .byTruncatingMiddle
        val.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [key, val])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .firstBaseline
        return stack
    }
}
