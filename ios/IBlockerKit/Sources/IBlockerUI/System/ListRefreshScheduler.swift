#if os(iOS)
import Foundation
import BackgroundTasks
import NetworkExtension
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
            await checkTunnelGone()
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

    /// Event 3 backstop for when the tunnel can't report its own stop: the
    /// marker isn't set, the VPN isn't connected or connecting, and no event 3
    /// episode is open. Posts once per outage; the restore follows when the
    /// tunnel is next seen connected.
    static func checkTunnelGone() async {
        let kind = StatusNotificationKind.protectionStopped
        let settings = AppEnvironment.settings
        let status: NEVPNStatus
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            guard let manager = managers.first else {
                log.info("tunnel-gone check: no VPN configuration, skipped")
                return
            }
            status = manager.connection.status
        } catch {
            log.error("tunnel-gone check: loading VPN configuration failed: \(error)")
            return
        }
        let running: Bool
        switch status {
        case .connected, .connecting, .reasserting: running = true
        default: running = false
        }
        let marker = settings.userTurnedOff
        let state = StatusNotificationState.load(from: settings)
        let alreadyNotified = state.episode(kind).isOpen

        let events: [StatusNotificationEvent]
        let result: String
        if running {
            events = alreadyNotified ? [.problemCleared(kind)] : []
            result = alreadyNotified ? "tunnel connected, restoring" : "tunnel connected"
        } else if marker {
            events = []
            result = "tunnel off, user turned off"
        } else if alreadyNotified {
            events = []
            result = "tunnel gone, already notified"
        } else {
            // Pending 6 (pause ended) and 7 (degraded) are meaningless now.
            events = [.tunnelStopped, .problemStarted(kind)]
            result = "tunnel gone, notifying"
        }
        log.info("tunnel-gone check: \(result) (status \(status.rawValue), marker \(marker))")
        guard !events.isEmpty else { return }

        var current = state
        var decisions: [StatusNotificationDecision] = []
        let now = Date()
        let preferences = StatusNotificationPreferences(settings: settings)
        for event in events {
            let decision = StatusNotificationPolicy.decide(event: event, state: current, preferences: preferences, now: now)
            current = decision.state
            decisions.append(decision)
        }
        current.save(to: settings)
        let poster = NotificationPoster(preferences: {
            StatusNotificationPreferences(settings: AppEnvironment.settings)
        })
        for decision in decisions {
            await poster.execute(decision, now: now)
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
