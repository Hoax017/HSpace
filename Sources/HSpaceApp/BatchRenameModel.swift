import BatchRename
import Foundation

/// State of the batch rename sheet, free of AppKit: selected items + steps → a preview plan.
/// The plan reads the disk and may run a slow regular expression, so it is built off the main thread. Only the newest result is kept.
@MainActor
final class BatchRenameModel {
    let items: [RenameItem]
    private(set) var steps: [RenameStep]
    private(set) var plan: RenamePlan?
    /// Why the steps cannot run, shown in place of the plan
    private(set) var stepError: String?
    var onChange: (() -> Void)?

    private var generation = 0
    private var pending: Task<Void, Never>?

    init(items: [RenameItem], steps: [RenameStep]) {
        self.items = items
        self.steps = steps
    }

    var canApply: Bool { stepError == nil && plan?.canApply == true }

    var summary: String {
        if let stepError { return stepError }
        guard let plan else { return "" }
        if plan.blockedCount > 0 { return L10n.f("rename.summary.blocked", plan.blockedCount) }
        if plan.changeCount == 0 { return L10n.t("rename.summary.none") }
        return L10n.f("rename.summary.ready", plan.changeCount)
    }

    /// A pause while typing, so a large selection is not re-planned for every key
    func setSteps(_ steps: [RenameStep]) {
        self.steps = steps
        pending?.cancel()
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            await self?.refresh()
        }
    }

    /// Waits for the plan of the latest `setSteps`.
    func settle() async { await pending?.value }

    func refresh() async {
        generation += 1
        let current = generation
        let items = items, steps = steps
        let outcome = await Task.detached { () -> Result<RenamePlan, any Error> in
            Result { try BatchRenamePlanner.plan(items: items, steps: steps) }
        }.value
        guard current == generation else { return }
        switch outcome {
        case .success(let plan):
            self.plan = plan
            stepError = nil
        case .failure(let error):
            plan = nil
            stepError = error.localizedDescription
        }
        onChange?()
    }

    static func text(for status: RenameRowStatus) -> String {
        switch status {
        case .unchanged: return L10n.t("rename.status.unchanged")
        case .ready: return L10n.t("rename.status.ready")
        case .blocked(.emptyName): return L10n.t("rename.status.empty")
        case .blocked(.invalidName): return L10n.t("rename.status.invalid")
        case .blocked(.nameTooLong): return L10n.t("rename.status.tooLong")
        case .blocked(.duplicateInBatch): return L10n.t("rename.status.duplicate")
        case .blocked(.existsOnDisk): return L10n.t("rename.status.exists")
        case .blocked(.sourceMissing): return L10n.t("rename.status.missing")
        }
    }
}
