import AppKit
import FileInspector
import FileMetadata
import HSpaceContracts
import UniformTypeIdentifiers

/// One line of the inspector
struct InspectorRow: Equatable {
    let label: String
    let value: String
}

/// Turns facts into lines. Anything unknown is left out, so the panel never shows an empty label.
@MainActor
enum InspectorRows {
    private static let duration: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute, .second]
        f.zeroFormattingBehavior = .pad
        return f
    }()

    static func kind(_ typeID: String?, isDirectory: Bool) -> String {
        Formatters.kind(forTypeID: typeID, isDirectory: isDirectory)
    }

    static func rows(for facts: InspectorFacts, tags: [FinderTag] = [], comment: String? = nil, folderBytes: FolderBytes = .notWanted) -> [InspectorRow] {
        var rows = [InspectorRow(label: L10n.t("info.kind"), value: kind(facts.typeID, isDirectory: facts.isDirectory))]
        func add(_ key: String, _ value: String?) {
            if let value { rows.append(InspectorRow(label: L10n.t(key), value: value)) }
        }
        add("info.size", sizeText(facts, folderBytes))
        if let allocated = facts.allocatedSize { add("inspector.onDisk", Formatters.size.string(fromByteCount: allocated)) }
        if let children = facts.childCount { add("inspector.items", L10n.f("inspector.itemCount", children)) }
        if let image = facts.image {
            add("inspector.dimensions", L10n.f("inspector.pixels", image.pixelWidth, image.pixelHeight))
            add("inspector.colorModel", image.colorModel)
            add("inspector.dpi", image.dpi.map { String(Int($0.rounded())) })
        }
        if let media = facts.media {
            add("inspector.duration", media.duration.flatMap { duration.string(from: $0) })
            if let width = media.videoWidth, let height = media.videoHeight {
                add("inspector.dimensions", L10n.f("inspector.pixels", width, height))
            }
        }
        if let pages = facts.pageCount { add("inspector.pages", String(pages)) }
        add("info.created", facts.created.map { Formatters.relativeDate($0) })
        add("info.modified", facts.modified.map { Formatters.relativeDate($0) })
        add("inspector.accessed", facts.accessed.map { Formatters.relativeDate($0) })
        add("inspector.added", facts.added.map { Formatters.relativeDate($0) })
        if let mode = facts.permissions {
            add("inspector.permissions", "\(Permissions.symbolic(mode)) (\(Permissions.octal(mode)))")
        }
        add("inspector.owner", facts.owner)
        add("inspector.group", facts.group)
        if facts.isSymlink {
            add("inspector.linkTarget", facts.linkTarget.map { facts.linkIsBroken ? L10n.f("inspector.linkBroken", $0) : $0 })
        }
        if facts.isLocked { add("inspector.locked", L10n.t("inspector.yes")) }
        if facts.isHidden { add("inspector.hidden", L10n.t("inspector.yes")) }
        if !tags.isEmpty { add("info.tags", tags.map(\.name).joined(separator: ", ")) }
        add("info.comment", comment)
        add("info.path", facts.url.path)
        return rows
    }

    /// How far a folder's recursive size has got
    enum FolderBytes: Equatable {
        case notWanted, calculating, known(Int64), unreadable
    }

    private static func sizeText(_ facts: InspectorFacts, _ folder: FolderBytes) -> String? {
        if let size = facts.logicalSize { return Formatters.size.string(fromByteCount: size) }
        switch folder {
        case .notWanted: return nil
        case .calculating: return L10n.t("inspector.calculating")
        case .known(let bytes): return Formatters.size.string(fromByteCount: bytes)
        case .unreadable: return L10n.t("inspector.unreadable")
        }
    }

    static func rows(for tally: SelectionTally, stillCounting: Bool) -> [InspectorRow] {
        var rows = [InspectorRow(label: L10n.t("inspector.items"), value: L10n.f("inspector.itemCount", tally.count))]
        if let shared = tally.sharedTypeID {
            rows.append(InspectorRow(label: L10n.t("info.kind"), value: kind(shared, isDirectory: tally.folders == tally.count)))
        }
        let size = Formatters.size.string(fromByteCount: tally.bytes)
        let text = stillCounting ? L10n.t("inspector.calculating")
            : tally.isPartial ? L10n.f("inspector.atLeast", size) : size
        rows.append(InspectorRow(label: L10n.t("info.size"), value: text))
        return rows
    }
}

/// Facts about the selection, or about the folder when nothing is selected. Each change cancels the previous read.
@MainActor
final class InspectorSectionView: NSView {
    private let header = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private var task: Task<Void, Never>?
    private var shown: [URL] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        header.font = .systemFont(ofSize: 12)
        header.lineBreakMode = .byTruncatingMiddle
        header.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        for sub in [header, scroll] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -8),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    func show(selection: [FileItem], directory: URL) {
        let wanted = selection.isEmpty ? [directory] : selection.map(\.url)
        guard wanted != shown else { return }
        shown = wanted
        task?.cancel()
        if selection.count > 1 {
            showSeveral(selection)
        } else {
            showOne(wanted[0])
        }
    }

    /// Lets the next `show` read again, for changes the selection does not reveal
    func clear() {
        task?.cancel()
        task = nil
        shown = []
    }

    private func showOne(_ url: URL) {
        header.stringValue = url.path == "/" ? "/" : url.lastPathComponent
        task = Task { [weak self] in
            do {
                let facts = try await Engines.inspector.inspect(url)
                let about = try? await Engines.metadata.read([url])
                guard let self, !Task.isCancelled else { return }
                let tags = about?[url]?.tags ?? []
                let comment = about?[url]?.comment
                let folder = facts.isDirectory && !facts.isPackage
                self.present(InspectorRows.rows(for: facts, tags: tags, comment: comment,
                                                folderBytes: folder ? .calculating : .notWanted))
                guard folder else { return }
                let bytes: InspectorRows.FolderBytes
                do {
                    bytes = .known(try await Engines.folderSize.size(of: url))
                } catch is CancellationError {
                    return
                } catch {
                    bytes = .unreadable
                }
                guard !Task.isCancelled else { return }
                self.present(InspectorRows.rows(for: facts, tags: tags, comment: comment, folderBytes: bytes))
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.present([InspectorRow(label: L10n.t("inspector.problem"), value: error.localizedDescription)])
            }
        }
    }

    private func showSeveral(_ items: [FileItem]) {
        header.stringValue = L10n.f("inspector.itemCount", items.count)
        let tally = SelectionTally(items)
        present(InspectorRows.rows(for: tally, stillCounting: tally.isPartial))
        guard tally.isPartial else { return }
        let folders = items.filter { $0.size == nil }.map(\.url)
        task = Task { [weak self] in
            var bytes: Int64 = 0
            var complete = true
            for folder in folders {
                do {
                    bytes += try await Engines.folderSize.size(of: folder)
                } catch is CancellationError {
                    return
                } catch {
                    complete = false
                }
                if Task.isCancelled { return }
            }
            self?.present(InspectorRows.rows(for: tally.adding(folderBytes: bytes, complete: complete), stillCounting: false))
        }
    }

    private func present(_ rows: [InspectorRow]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for row in rows { stack.addArrangedSubview(Self.line(row)) }
    }

    private static func line(_ row: InspectorRow) -> NSView {
        let label = ToolUI.label(row.label)
        let value = NSTextField(wrappingLabelWithString: row.value)
        value.font = .systemFont(ofSize: 11)
        value.isSelectable = true
        value.setAccessibilityLabel(row.label)
        let line = NSStackView(views: [label, value])
        line.orientation = .vertical
        line.alignment = .leading
        line.spacing = 2
        return line
    }

    var testRows: [String] {
        stack.arrangedSubviews.compactMap { ($0 as? NSStackView)?.arrangedSubviews.last as? NSTextField }.map(\.stringValue)
    }
    var testHeader: String { header.stringValue }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
