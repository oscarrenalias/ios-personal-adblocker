import Foundation
import UserNotifications

/// The slice of `UNUserNotificationCenter` the poster uses, so tests can
/// substitute a fake.
public protocol NotificationCenterProviding: Sendable {
    func add(_ request: UNNotificationRequest) async throws
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
}

extension UNUserNotificationCenter: NotificationCenterProviding {
    public func authorizationStatus() async -> UNAuthorizationStatus {
        await notificationSettings().authorizationStatus
    }
}

/// Thin wrapper over the notification center. It checks the master switch and
/// type toggles before scheduling or posting, carries out policy decisions,
/// and logs under category `notify`. Failures are logged, never thrown.
/// Logs carry kinds, delays and errors only, never domain names.
public struct NotificationPoster: Sendable {
    private let center: NotificationCenterProviding
    private let preferences: @Sendable () -> StatusNotificationPreferences
    private let log: Log

    public init(
        center: NotificationCenterProviding = UNUserNotificationCenter.current(),
        preferences: @escaping @Sendable () -> StatusNotificationPreferences,
        log: Log = Log(category: "notify")
    ) {
        self.center = center
        self.preferences = preferences
        self.log = log
    }

    // MARK: Authorization

    public func isAuthorized() async -> Bool {
        switch await center.authorizationStatus() {
        case .authorized, .provisional, .ephemeral: true
        default: false
        }
    }

    public func authorizationStatus() async -> UNAuthorizationStatus {
        await center.authorizationStatus()
    }

    /// Asks the system for permission. Returns false when denied or on error.
    @discardableResult
    public func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            log.notice("authorization requested: \(granted ? "granted" : "denied")")
            return granted
        } catch {
            log.error("authorization request failed: \(error)")
            return false
        }
    }

    // MARK: Posting

    /// Schedules `content` to fire after `delay` seconds, replacing any
    /// pending request with the same identifier.
    public func schedule(_ kind: StatusNotificationKind, content: StatusNotificationContent, delay: TimeInterval) async {
        guard await mayPost(kind) else { return }
        // Time-interval triggers must be positive.
        let seconds = max(1, delay)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        if await add(content, trigger: trigger, kind: kind) {
            log.notice("scheduled \(kind.rawValue) in \(Int(delay.rounded())) s")
        }
    }

    public func cancelPending(_ kind: StatusNotificationKind, clearedAfter: TimeInterval?) {
        center.removePendingNotificationRequests(withIdentifiers: [kind.notificationIdentifier])
        if let clearedAfter {
            log.info("cancelled pending \(kind.rawValue) (cleared after \(Int(clearedAfter.rounded())) s)")
        } else {
            log.info("cancelled pending \(kind.rawValue)")
        }
    }

    /// Posts the restore for `kind` now, replacing that problem's notification.
    public func postRestore(forKind kind: StatusNotificationKind, resolverName: String? = nil) async {
        guard await mayPost(.restored, blockedBy: kind) else { return }
        guard let content = StatusNotificationContentBuilder.restore(forKind: kind, resolverName: resolverName) else {
            log.debug("no restore content for \(kind.rawValue)")
            return
        }
        if await add(content, trigger: nil, kind: kind) {
            log.notice("posted restored for \(kind.rawValue)")
        }
    }

    // MARK: Decisions

    /// Carries out `decision`: logs suppressions and the trace, then runs each
    /// action. `resolverName` and `listName` feed the content builders.
    public func execute(
        _ decision: StatusNotificationDecision,
        now: Date = Date(),
        resolverName: String? = nil,
        listName: String? = nil
    ) async {
        for line in decision.trace { log.debug(line) }
        for s in decision.suppressions {
            log.info("suppressed \(s.kind.rawValue): \(s.reason.rawValue)")
        }
        for action in decision.actions {
            switch action {
            case .schedule(let kind, let fireDate):
                guard let content = StatusNotificationContentBuilder.problem(
                    kind, resolverName: resolverName, listName: listName
                ) else {
                    log.debug("no problem content for \(kind.rawValue)")
                    continue
                }
                await schedule(kind, content: content, delay: fireDate.timeIntervalSince(now))
            case .cancel(let kind, let clearedAfter):
                cancelPending(kind, clearedAfter: clearedAfter)
            case .postRestore(let kind):
                await postRestore(forKind: kind, resolverName: resolverName)
            }
        }
    }

    // MARK: Private

    /// Preferences, then system authorization. Logs the reason when blocked.
    /// `blockedBy` is the problem kind whose toggle governs a restore.
    private func mayPost(_ kind: StatusNotificationKind, blockedBy toggleKind: StatusNotificationKind? = nil) async -> Bool {
        if let reason = preferences().blockReason(for: toggleKind ?? kind) {
            log.info("suppressed \(kind.rawValue): \(reason.rawValue)")
            return false
        }
        guard await isAuthorized() else {
            log.info("suppressed \(kind.rawValue): not authorized")
            return false
        }
        return true
    }

    private func add(_ content: StatusNotificationContent, trigger: UNNotificationTrigger?, kind: StatusNotificationKind) async -> Bool {
        let mutable = UNMutableNotificationContent()
        mutable.title = content.title
        mutable.body = content.body
        mutable.userInfo = content.userInfo
        let request = UNNotificationRequest(identifier: content.identifier, content: mutable, trigger: trigger)
        do {
            try await center.add(request)
            return true
        } catch {
            log.error("add failed for \(kind.rawValue): \(error)")
            return false
        }
    }
}
