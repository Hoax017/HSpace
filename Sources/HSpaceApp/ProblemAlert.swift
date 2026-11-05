import AppKit
import HSpaceContracts

/// Shows failures the stores could not throw to anyone, such as a damaged file kept aside at load.
/// An alert rather than a toast, because the message holds a file path the user needs time to read.
@MainActor
enum ProblemAlert {
    private static var waiting: [String] = []
    private static var shown: Set<String> = []
    /// An alert is up, or a problem is waiting for a free window
    private(set) static var isBusy = false

    /// Each message appears once per run: a disk that stays full must not raise an alert on every save.
    static func show(_ problem: (any ClassifiedError)?) {
        guard let problem, shown.insert(problem.localizedDescription).inserted else { return }
        waiting.append(problem.localizedDescription)
        showNext()
    }

    private static func showNext() {
        guard !isBusy, !waiting.isEmpty else { return }
        isBusy = true
        let windows = NSApp.windows.filter { $0.windowController is MainWindowController && $0.isVisible }
        guard let window = windows.first(where: { $0.attachedSheet == nil }) else {
            // Still launching, or a conflict panel is open. Only runs while a problem waits.
            Task {
                try? await Task.sleep(for: .seconds(1))
                isBusy = false
                showNext()
            }
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t("alert.storeProblem.title")
        alert.informativeText = waiting.removeFirst()
        alert.beginSheetModal(for: window) { _ in
            MainActor.assumeIsolated {
                isBusy = false
                showNext()
            }
        }
    }
}
