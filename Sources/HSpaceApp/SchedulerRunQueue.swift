import Foundation
import HSpaceContracts
import HSpaceKernel
import Scheduler

/// Composes the Scheduler pod into the kernel's queue seam (pods and the kernel do not know each other).
final class SchedulerRunQueue: RunQueue {
    private let scheduler: Scheduler

    init(_ scheduler: Scheduler) { self.scheduler = scheduler }

    func enqueue(_ id: UUID, spec: OperationSpec) { scheduler.enqueue(SchedulerRequest(id: id, spec: spec)) }
    func takeRunnable() -> [UUID] { scheduler.takeRunnable() }
    func withdraw(_ id: UUID) { scheduler.withdraw(id) }
    func finished(_ id: UUID) { scheduler.finished(id) }
    func setWakeHandler(_ handler: @escaping @Sendable () -> Void) { scheduler.setWakeHandler(handler) }
}
