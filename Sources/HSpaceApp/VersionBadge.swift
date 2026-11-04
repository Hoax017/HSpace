import AppKit

/// App version reader (the single read point): uses Bundle.main's Info.plist (build-app.sh injects into the .app
/// CFBundleShortVersionString=VERSION / CFBundleVersion=git commit count).
/// A bare binary (swift run during development) has no Info.plist, so it falls back to a placeholder rather than crashing.
@MainActor
enum AppVersion {
    /// Short version (such as "0.9.3"); falls back to "0.0.0"
    static var shortVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "0.0.0"
    }

    /// Build number (such as "482"); falls back to "0"
    static var buildNumber: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "0"
    }
}

/// Version badge: small read-only pill at the trailing end of the workspace tab bar.
/// Shows "v{short version}" with the build number in its tooltip.
@MainActor
final class VersionBadgeView: NSView {
    private let label = NSTextField(labelWithString: "")

    /// The deck sits in the title bar area, so window dragging must not swallow this view.
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8

        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 20),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        let version = AppVersion.shortVersion
        label.stringValue = "v\(version)"
        label.textColor = .secondaryLabelColor
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
        toolTip = L10n.f("badge.tooltip", version, AppVersion.buildNumber)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UI is built in code; no xib") }
}
