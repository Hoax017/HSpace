import AppKit

/// App 版本读取（唯一读取点）：走 Bundle.main 的 Info.plist（.app 包内由 build-app.sh 注入
/// CFBundleShortVersionString=VERSION / CFBundleVersion=git 提交数）。
/// 裸二进制（swift run 开发态）无 Info.plist 时回退占位，不崩。
@MainActor
enum AppVersion {
    /// 短版本号（如 "0.9.3"）；缺省回退 "0.0.0"
    static var shortVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "0.0.0"
    }

    /// 构建号（如 "482"）；缺省回退 "0"
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
