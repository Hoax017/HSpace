import AppKit
import SidebarColors

/// Appearance settings page (v1 subset of QSpace's appearance options): light/dark mode / theme palette / list font size / active pane highlight / inactive pane dimming.
/// Everything applies immediately and persists: mode, accent, highlight and dimming refresh via Theme.broadcastChanged; font size refreshes through the column rebuild path.
@MainActor
final class AppearanceSettingsPage: NSObject, SettingsPage {
    var pageTitleKey: String { "settings.tab.appearance" }

    /// Light/dark mode radio group (0 = system / 1 = light / 2 = dark)
    private var modeButtons: [NSButton] = []
    /// Swatch buttons (tag = palette index; the system entry has tag = -1)
    private var accentButtons: [NSButton] = []
    private let dimValueLabel = NSTextField(labelWithString: "")

    func makeView() -> NSView {
        let stack = NSStackView(views: [
            sectionLabel("settings.appearance.mode"),
            buildModeRow(),
            NSBox.separatorLine(),
            sectionLabel("settings.appearance.accent"),
            buildAccentRow(),
            NSBox.separatorLine(),
            buildFontRow(),
            buildHighlightRow(),
            buildDimRow(),
            NSBox.separatorLine(),
            buildSidebarPaletteRow(),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        refreshAccentSelection()

        let v = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: v.topAnchor),
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor),
        ])
        return v
    }

    // MARK: Sidebar palette (L33)

    private func buildSidebarPaletteRow() -> NSView {
        let popup = NSPopUpButton()
        for palette in SidebarPalette.allCases {
            popup.addItem(withTitle: palette.title)
            popup.lastItem?.representedObject = palette.rawValue
        }
        popup.selectItem(at: SidebarPalette.allCases.firstIndex(of: SidebarColorsHost.store.settings().palette) ?? 0)
        popup.target = self
        popup.action = #selector(sidebarPaletteChanged(_:))
        let label = NSTextField(labelWithString: L10n.t("settings.appearance.sidebarPalette"))
        label.font = .systemFont(ofSize: 12)
        popup.setAccessibilityLabel(label.stringValue)
        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    @objc private func sidebarPaletteChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String, let palette = SidebarPalette(rawValue: raw) else { return }
        if let failure = SidebarColorsHost.apply({ try SidebarColorsHost.store.setPalette(palette) }) {
            ToolUI.showError(failure, in: sender.window)
            sender.selectItem(at: SidebarPalette.allCases.firstIndex(of: SidebarColorsHost.store.settings().palette) ?? 0)
        }
    }

    // MARK: Section titles

    private func sectionLabel(_ key: String) -> NSTextField {
        let label = NSTextField(labelWithString: L10n.t(key))
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        return label
    }

    // MARK: Light/dark mode (three radios)

    private func buildModeRow() -> NSView {
        let specs: [(tag: Int, key: String)] = [
            (0, "settings.appearance.system"),
            (1, "settings.appearance.light"),
            (2, "settings.appearance.dark"),
        ]
        let current = modeTag(for: Preferences.appearanceMode)
        for spec in specs {
            let b = NSButton(radioButtonWithTitle: L10n.t(spec.key),
                             target: self, action: #selector(modeChanged(_:)))
            b.tag = spec.tag
            b.font = .systemFont(ofSize: 12)
            b.state = spec.tag == current ? .on : .off
            modeButtons.append(b)
        }
        let row = NSStackView(views: modeButtons)
        row.orientation = .horizontal
        row.spacing = 16
        return row
    }

    private func modeTag(for raw: String) -> Int {
        switch raw {
        case "light": 1
        case "dark": 2
        default: 0
        }
    }

    @objc private func modeChanged(_ sender: NSButton) {
        for b in modeButtons { b.state = b === sender ? .on : .off }
        Preferences.appearanceMode = switch sender.tag {
            case 1: "light"
            case 2: "dark"
            default: "system"
        }
        Theme.broadcastChanged()
    }

    // MARK: Theme palette (8 colors + system entry)

    private func buildAccentRow() -> NSView {
        // System entry (tag = -1): follows the system accent color
        let systemDot = accentDot(color: .controlAccentColor, tag: -1,
                                  tooltip: L10n.t("accent.system"), showGlyph: true)
        accentButtons.append(systemDot)
        var dots: [NSView] = [systemDot]
        for (i, c) in Theme.accentPalette.enumerated() {
            let dot = accentDot(color: NSColor(hex: c.hex) ?? .controlAccentColor, tag: i,
                                tooltip: L10n.t(c.nameKey), showGlyph: false)
            accentButtons.append(dot)
            dots.append(dot)
        }
        let row = NSStackView(views: dots)
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    /// One swatch: borderless round button; the selected state gets a white/gray ring
    private func accentDot(color: NSColor, tag: Int, tooltip: String, showGlyph: Bool) -> NSButton {
        let b = NSButton()
        b.title = ""
        b.tag = tag
        b.toolTip = tooltip
        b.isBordered = false
        b.wantsLayer = true
        b.target = self
        b.action = #selector(accentChanged(_:))
        b.layer?.cornerRadius = 8
        b.layer?.backgroundColor = color.cgColor
        b.layer?.borderColor = NSColor.controlBackgroundColor.cgColor
        if showGlyph {
            // The system entry gets a small dotted glyph to set it apart from solid colors
            b.image = NSImage(systemSymbolName: "circle.dashed",
                              accessibilityDescription: tooltip)
            b.imagePosition = .imageOnly
            b.contentTintColor = .white
        }
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: 16),
            b.heightAnchor.constraint(equalToConstant: 16),
        ])
        return b
    }

    @objc private func accentChanged(_ sender: NSButton) {
        Preferences.accentColorHex = sender.tag < 0 ? nil : Theme.accentPalette[sender.tag].hex
        refreshAccentSelection()
        Theme.broadcastChanged()
    }

    /// Refresh the swatch selection ring (matches the current preference)
    private func refreshAccentSelection() {
        let selectedTag: Int
        if let hex = Preferences.accentColorHex,
           let idx = Theme.accentPalette.firstIndex(where: { $0.hex.caseInsensitiveCompare(hex) == .orderedSame }) {
            selectedTag = idx
        } else {
            selectedTag = -1
        }
        for b in accentButtons {
            b.layer?.borderWidth = b.tag == selectedTag ? 2 : 0
        }
    }

    // MARK: List font size (11-14 popup)

    private func buildFontRow() -> NSView {
        let label = NSTextField(labelWithString: L10n.t("settings.appearance.fontSize"))
        label.font = .systemFont(ofSize: 12)
        let popup = NSPopUpButton()
        for size in 11...14 {
            popup.addItem(withTitle: "\(size)")
            popup.lastItem?.tag = size
        }
        popup.selectItem(withTag: Preferences.listFontSize)
        popup.target = self
        popup.action = #selector(fontSizeChanged(_:))
        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.spacing = 8
        label.widthAnchor.constraint(equalToConstant: 152).isActive = true
        return row
    }

    @objc private func fontSizeChanged(_ sender: NSPopUpButton) {
        Preferences.listFontSize = sender.selectedTag()
        // Reuse the column rebuild path: all list views rebuild columns and re-fetch font/row height for the new size
        NotificationCenter.default.post(name: .hspaceColumnsChanged, object: nil)
    }

    // MARK: Highlight active pane

    private func buildHighlightRow() -> NSButton {
        let b = NSButton(checkboxWithTitle: L10n.t("settings.appearance.highlightActive"),
                         target: self, action: #selector(highlightChanged(_:)))
        b.state = Preferences.activePaneHighlight ? .on : .off
        b.font = .systemFont(ofSize: 12)
        return b
    }

    @objc private func highlightChanged(_ sender: NSButton) {
        Preferences.activePaneHighlight = sender.state == .on
        Theme.broadcastChanged()
    }

    // MARK: Inactive pane dimming (0-30% slider)

    private func buildDimRow() -> NSView {
        let label = NSTextField(labelWithString: L10n.t("settings.appearance.dimInactive"))
        label.font = .systemFont(ofSize: 12)
        let slider = NSSlider(value: Preferences.inactivePaneDimming * 100, minValue: 0, maxValue: 30,
                              target: self, action: #selector(dimChanged(_:)))
        slider.isContinuous = true
        slider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        dimValueLabel.font = .systemFont(ofSize: 11)
        dimValueLabel.textColor = .secondaryLabelColor
        updateDimValueLabel()
        let row = NSStackView(views: [label, slider, dimValueLabel])
        row.orientation = .horizontal
        row.spacing = 8
        label.widthAnchor.constraint(equalToConstant: 152).isActive = true
        return row
    }

    @objc private func dimChanged(_ sender: NSSlider) {
        Preferences.inactivePaneDimming = sender.doubleValue / 100
        updateDimValueLabel()
        Theme.broadcastChanged()
    }

    private func updateDimValueLabel() {
        dimValueLabel.stringValue = "\(Int((Preferences.inactivePaneDimming * 100).rounded()))%"
    }
}
