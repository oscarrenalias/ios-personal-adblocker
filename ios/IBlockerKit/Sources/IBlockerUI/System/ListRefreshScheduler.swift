#if os(iOS)
import Foundation
import BackgroundTasks
import IBlockerKit

/// Best-effort background list refresh. iOS decides when (and whether) the
/// task runs, so the foreground staleness check in FilterListsViewModel is
/// the primary refresh path; this is the bonus.
public enum ListRefreshScheduler {

    /// Must be called before the app finishes launching (App.init).
    public static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: AppEnvironment.refreshTaskID,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refreshTask)
        }
        schedule()
    }

    private static let log = Log(category: "app")

    public static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: AppEnvironment.refreshTaskID)
        let earliest = Date(timeIntervalSinceNow: 6 * 3600)
        request.earliestBeginDate = earliest
        do {
            try BGTaskScheduler.shared.submit(request)
            log.info("background refresh scheduled (earliest \(earliest))")
        } catch {
            log.error("background refresh submit failed: \(error)")
        }
    }

    static func handle(_ task: BGAppRefreshTask) {
        // Whichever of completion/expiration comes first completes the task;
        // iOS treats a second setTaskCompleted as a programming error.
        let completion = Completion(task)
        let work = Task {
            let summary = await AppEnvironment.listStore.updateAll(force: false, trigger: .background)
            if summary.anyChanged {
                AppEnvironment.settings.lastListUpdate = Date()
            }
            schedule()
            let success = summary.failedSourceIDs.isEmpty
            log.notice("background refresh ran: \(success ? "success" : "partial failure")")
            completion.finish(success: success)
        }
        task.expirationHandler = {
            work.cancel()
            log.notice("background refresh expired")
            completion.finish(success: false)
        }
    }

    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private let task: BGAppRefreshTask

        init(_ task: BGAppRefreshTask) { self.task = task }

        func finish(success: Bool) {
            lock.lock()
            let first = !done
            done = true
            lock.unlock()
            if first { task.setTaskCompleted(success: success) }
        }
    }
}
#endif
