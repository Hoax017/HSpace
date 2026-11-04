import AppKit

/// L1 lightweight toast (three-tier notification model): non-blocking success feedback, fades after 2s.
/// Used for confirmations such as "Path copied/N items copied/Bookmark added", so the UI is not silent after an action.
@MainActor
enum Toast {
    private static var current: NSView?

    static func show(_ text: String, in window: NSWindow?) {
        guard let contentView = window?.contentView else { return }
        current?.removeFromSuperview()

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let pill = NSVisualEffectView()
        pill.material = .hudWindow
        pill.state = .active
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 16
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)
        contentView.addSubview(pill)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -8),
            pill.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            pill.bottomAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.bottomAnchor, constant: -32),
        ])
        current = pill
        pill.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            pill.animator().alphaValue = 1
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard current === pill else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                pill.animator().alphaValue = 0
            }, completionHandler: {
                Task { @MainActor in
                    pill.removeFromSuperview()
                    if current === pill { current = nil }
                }
            })
        }
    }
}
