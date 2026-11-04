import AppKit

/// Archive settings page (SettingsPage plugin): compression format / keep originals after compressing / extraction wrapper folder / keep archive after extracting.
/// Everything is stored in Preferences' externalized keys; controls apply immediately. Rendered as one tab of the settings window through SettingsPages.extraPages.
@MainActor
final class ArchiveSettingsPage: NSObject, SettingsPage {
    var pageTitleKey: String { "settings.tab.archive" }

    func makeView() -> NSView {
        // Scope note on top: this page covers only NSpace's own compress/extract commands; double-click always uses the system default app (I-06)
        let scopeNote = NSTextField(wrappingLabelWithString: L10n.t("settings.archiveScopeNote"))
        scopeNote.font = .systemFont(ofSize: 11)
        scopeNote.textColor = .secondaryLabelColor

        // Compression format popup
        let formatLabel = NSTextField(labelWithString: L10n.t("settings.archiveFormat"))
        formatLabel.font = .systemFont(ofSize: 12)
        let formatPopup = NSPopUpButton()
        for o in Preferences.archiveFormatOptions {
            formatPopup.addItem(withTitle: L10n.t(o.nameKey))
            formatPopup.lastItem?.representedObject = o.id
        }
        if let idx = Preferences.archiveFormatOptions.firstIndex(where: { $0.id == Preferences.archiveFormat }) {
            formatPopup.selectItem(at: idx)
        }
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged(_:))
        let formatRow = NSStackView(views: [formatLabel, formatPopup])
        formatRow.orientation = .horizontal
        formatRow.spacing = 8
        formatLabel.widthAnchor.constraint(equalToConstant: 152).isActive = true

        // Keep originals after compressing
        let keepOriginal = checkbox("settings.archiveKeepOriginal",
                                    checked: Preferences.archiveKeepOriginal,
                                    action: #selector(keepOriginalChanged(_:)))

        // Always create a wrapper folder on extraction + note
        let wrapper = checkbox("settings.extractCreateWrapper",
                               checked: Preferences.extractCreateWrapper,
                               action: #selector(wrapperChanged(_:)))
        let wrapperNote = NSTextField(wrappingLabelWithString: L10n.t("settings.extractWrapperNote"))
        wrapperNote.font = .systemFont(ofSize: 11)
        wrapperNote.textColor = .tertiaryLabelColor

        // Keep archive after extracting
        let keepArchive = checkbox("settings.extractKeepArchive",
                                   checked: Preferences.extractKeepArchive,
                                   action: #selector(keepArchiveChanged(_:)))

        // Honest note about weak encryption
        let cryptoNote = NSTextField(wrappingLabelWithString: L10n.t("settings.archiveCryptoNote"))
        cryptoNote.font = .systemFont(ofSize: 11)
        cryptoNote.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [scopeNote, NSBox.separatorLine(), formatRow, keepOriginal,
                                        NSBox.separatorLine(), wrapper, wrapperNote, keepArchive,
                                        NSBox.separatorLine(), cryptoNote])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
        ])
        return container
    }

    private func checkbox(_ titleKey: String, checked: Bool, action: Selector) -> NSButton {
        let b = NSButton(checkboxWithTitle: L10n.t(titleKey), target: self, action: action)
        b.state = checked ? .on : .off
        b.font = .systemFont(ofSize: 12)
        return b
    }

    @objc private func formatChanged(_ sender: NSPopUpButton) {
        if let id = sender.selectedItem?.representedObject as? String { Preferences.archiveFormat = id }
    }

    @objc private func keepOriginalChanged(_ sender: NSButton) {
        Preferences.archiveKeepOriginal = sender.state == .on
    }

    @objc private func wrapperChanged(_ sender: NSButton) {
        Preferences.extractCreateWrapper = sender.state == .on
    }

    @objc private func keepArchiveChanged(_ sender: NSButton) {
        Preferences.extractKeepArchive = sender.state == .on
    }
}
