import AppKit

/// Permissions settings page: Full Disk Access (FDA) status check + guidance. The check is a read-only probe (FinderIntegration.hasFullDiskAccess,
/// no BG-1 violation); the status line is green ✓ / orange ⚠, with "Open System Settings" and "Check Again" buttons and explanatory text.
@MainActor
final class PermissionsSettingsPage: NSObject, SettingsPage {
    var pageTitleKey: String { "settings.tab.permissions" }

    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    func makeView() -> NSView {
        let header = NSTextField(labelWithString: L10n.t("settings.perm.fdaTitle"))
        header.font = .systemFont(ofSize: 13, weight: .semibold)

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        refreshStatus()

        let openButton = NSButton(title: L10n.t("settings.perm.open"), target: self,
                                  action: #selector(openSettings))
        openButton.bezelStyle = .push
        let recheckButton = NSButton(title: L10n.t("settings.perm.recheck"), target: self,
                                     action: #selector(recheck))
        recheckButton.bezelStyle = .push
        let buttons = NSStackView(views: [openButton, recheckButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let note = NSTextField(wrappingLabelWithString: L10n.t("settings.perm.note"))
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [header, statusLabel, buttons,
                                        NSBox.separatorLine(), note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

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

    /// Re-probes and refreshes the status line (after granting, "Check Again" on this page shows it at once)
    private func refreshStatus() {
        if FinderIntegration.hasFullDiskAccess() {
            statusLabel.stringValue = L10n.t("settings.perm.granted")
            statusLabel.textColor = .systemGreen
        } else {
            statusLabel.stringValue = L10n.t("settings.perm.denied")
            statusLabel.textColor = .systemOrange
        }
    }

    @objc private func openSettings() {
        FinderIntegration.openFullDiskAccessSettings()
    }

    @objc private func recheck() {
        refreshStatus()
    }
}
