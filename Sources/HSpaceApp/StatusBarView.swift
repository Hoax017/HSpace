import AppKit

/// Pane bottom status bar (QSpace style, 24pt): "N items (M selected)" on the left, "X GB available" on the right.
/// Volume capacity is read once per directory change/tab switch (read-only cost at statfs level), never polled: north star zero idle power.
@MainActor
final class StatusBarView: NSView {
    private let countLabel = NSTextField(labelWithString: "")
    private let spaceLabel = NSTextField(labelWithString: "")
    /// Selection pill (10% accent background, corner radius = height/2, tabular digits): shown only with a selection; otherwise only the total countLabel stays
    private let selectionPill = NSView()
    private let selectionLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        // Count/available capacity: tabular digits (tabular-nums) so numbers do not jitter on refresh (Tufte)
        for label in [countLabel, spaceLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }

        // Selection pill (modeled on the stash count pill): 16pt centered in the 24pt bar, corner radius 8 = height/2
        selectionPill.wantsLayer = true
        selectionPill.layer?.cornerRadius = 8
        selectionPill.isHidden = true
        selectionPill.identifier = .init("statusSelectionPill")
        selectionPill.translatesAutoresizingMaskIntoConstraints = false
        selectionLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        selectionLabel.textColor = .labelColor
        selectionLabel.lineBreakMode = .byTruncatingTail
        selectionLabel.translatesAutoresizingMaskIntoConstraints = false
        selectionPill.addSubview(selectionLabel)
        addSubview(selectionPill)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            countLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            selectionPill.leadingAnchor.constraint(equalTo: countLabel.trailingAnchor, constant: 8),
            selectionPill.centerYAnchor.constraint(equalTo: centerYAnchor),
            selectionPill.heightAnchor.constraint(equalToConstant: 16),
            selectionLabel.leadingAnchor.constraint(equalTo: selectionPill.leadingAnchor, constant: 8),
            selectionLabel.trailingAnchor.constraint(equalTo: selectionPill.trailingAnchor, constant: -8),
            selectionLabel.centerYAnchor.constraint(equalTo: selectionPill.centerYAnchor),
            spaceLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            spaceLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            selectionPill.trailingAnchor.constraint(lessThanOrEqualTo: spaceLabel.leadingAnchor, constant: -8),
        ])
        applyAccentColor()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: .hspaceThemeChanged, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// UISelfTest probe: whether the selection pill is currently visible
    var selectionPillVisible: Bool { !selectionPill.isHidden }

    /// Pill background is 10% accent (appearance-aware: re-resolved on light/dark or accent changes; see StashShelfView.applyAccentColors)
    private func applyAccentColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            selectionPill.layer?.backgroundColor = Theme.accent.withAlphaComponent(0.10).cgColor
        }
    }

    @objc private func themeChanged() { applyAccentColor() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAccentColor()
    }

    // Appearance-aware opaque backing: updateLayer re-resolves it on light/dark switches. Without a backing,
    // this 24pt status bar was invisible in dark mode self-rendered screenshots (item count/free space unreadable).
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    /// Counts: countLabel always shows the total "N items"; with a selection the pill shows "M selected · size", otherwise the pill is hidden
    func update(itemCount: Int, selectedCount: Int, selectedBytes: Int64) {
        countLabel.stringValue = String(format: L10n.t("status.items"), itemCount)
        if selectedCount > 0 {
            let sizeStr = selectedBytes > 0 ? Formatters.size.string(fromByteCount: selectedBytes) : ""
            selectionLabel.stringValue = sizeStr.isEmpty
                ? String(format: L10n.t("status.selectedCount"), selectedCount)
                : String(format: L10n.t("status.selectedPill"), selectedCount, sizeStr)
            selectionPill.isHidden = false
        } else {
            selectionPill.isHidden = true
        }
    }

    /// Free space on the right: reads the important-usage available capacity of the current directory's volume (read once, never polled);
    /// left blank when unreadable or 0 (read-only volumes, DMGs, etc.) rather than showing a misleading "0 KB available"
    func updateVolume(for url: URL) {
        let capacity = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        spaceLabel.stringValue = capacity > 0
            ? String(format: L10n.t("status.available"), Formatters.size.string(fromByteCount: capacity))
            : ""
    }
}
