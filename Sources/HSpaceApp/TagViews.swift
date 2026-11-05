import AppKit
import FileMetadata

/// Finder's tag colours as system colours (the Zero-Hex rule: light and dark resolve by themselves)
@MainActor
enum TagPalette {
    static func color(_ tag: TagColor) -> NSColor {
        switch tag {
        case .none: return .tertiaryLabelColor
        case .gray: return .systemGray
        case .green: return .systemGreen
        case .purple: return .systemPurple
        case .blue: return .systemBlue
        case .yellow: return .systemYellow
        case .red: return .systemRed
        case .orange: return .systemOrange
        }
    }

    static func name(_ tag: TagColor) -> String {
        L10n.t("tags.color.\(tag.rawValue)")
    }

    /// Official symbol tinted with the tag colour, for menus. Tags without a colour get a hollow circle, as in Finder.
    static func menuImage(_ tag: TagColor, size: CGFloat = 12) -> NSImage? {
        let symbol = tag == .none ? "circle" : "circle.fill"
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
            .applying(.init(paletteColors: [color(tag)]))
        return NSImage.officialSymbol(symbol)?.withSymbolConfiguration(config)
    }
}

/// Up to three overlapping dots for an item's tags, last tag on top as in Finder. Zero width without tags.
@MainActor
final class TagDotsView: NSStackView {
    private static let limit = 3

    /// Colours currently shown, oldest first
    private(set) var shownColors: [TagColor] = []

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = -4
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    func show(_ tags: [FinderTag]) {
        let colors = Array(tags.suffix(Self.limit).map(\.color))
        toolTip = tags.isEmpty ? nil : tags.map(\.name).joined(separator: ", ")
        setAccessibilityLabel(toolTip.map { L10n.f("tags.a11y", $0) })
        guard colors != shownColors else { return }
        shownColors = colors
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        for color in colors {
            let dot = NSImageView()
            dot.image = TagPalette.menuImage(color, size: 8)
            dot.setAccessibilityElement(false)
            addArrangedSubview(dot)
        }
    }
}
