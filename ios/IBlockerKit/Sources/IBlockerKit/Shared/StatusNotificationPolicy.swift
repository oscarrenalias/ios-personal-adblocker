import Foundation

/// The status notifications the app and tunnel can raise. Pure data: no
/// UserNotifications types, so policy and content logic stay unit-testable.
public enum StatusNotificationKind: String, Sendable, Equatable, CaseIterable {
    case resolverFallback = "resolver-fallback"
    case resolverFailing = "resolver-failing"
    case protectionStopped = "protection-stopped"
    case restored
    case listRejected = "list-rejected"
    case listStale = "list-stale"
    case pauseEnded = "pause-ended"
    case degraded

    /// The tab a tap on the notification opens.
    public enum Tab: String, Sendable, Equatable {
        case dashboard
        case lists
    }

    /// The Settings toggle group that controls a kind.
    public enum PreferenceType: String, Sendable, Equatable {
        case encryptedDNS
        case protectionStopped
        case pauseEnded
        case blocklists
    }

    /// Seconds a problem must last before its notification appears. Zero for
    /// kinds that are posted right away.
    public var debounceDelay: TimeInterval {
        switch self {
        case .resolverFallback, .resolverFailing: 30
        case .protectionStopped: 60
        case .degraded: 5 * 60
        case .restored, .listRejected, .listStale, .pauseEnded: 0
        }
    }

    public var targetTab: Tab {
        switch self {
        case .listRejected, .listStale: .lists
        default: .dashboard
        }
    }

    /// Minimum spacing between two notifications of the same kind.
    public static let rateLimitInterval: TimeInterval = 5 * 60

    /// The preference toggle for this kind. Restores follow the problem they
    /// belong to, so `.restored` has no toggle of its own.
    public var preferenceType: PreferenceType? {
        switch self {
        case .resolverFallback, .resolverFailing: .encryptedDNS
        case .protectionStopped, .degraded: .protectionStopped
        case .pauseEnded: .pauseEnded
        case .listRejected, .listStale: .blocklists
        case .restored: nil
        }
    }
}

/// Why a tunnel stopped, mirroring `NEProviderStopReason` without importing
/// NetworkExtension. `init(rawValue:)` maps the NE raw values.
public enum TunnelStopReason: Sendable, Equatable {
    case none
    case userInitiated
    case providerFailed
    case noNetworkAvailable
    case unrecoverableNetworkChange
    case providerDisabled
    case authenticationCanceled
    case configurationFailed
    case idleTimeout
    case configurationDisabled
    case configurationRemoved
    case superceded
    case userLogout
    case userSwitch
    case connectionFailed
    case sleep
    case appUpdate
    case other(Int)

    public init(rawValue: Int) {
        switch rawValue {
        case 0: self = .none
        case 1: self = .userInitiated
        case 2: self = .providerFailed
        case 3: self = .noNetworkAvailable
        case 4: self = .unrecoverableNetworkChange
        case 5: self = .providerDisabled
        case 6: self = .authenticationCanceled
        case 7: self = .configurationFailed
        case 8: self = .idleTimeout
        case 9: self = .configurationDisabled
        case 10: self = .configurationRemoved
        case 11: self = .superceded
        case 12: self = .userLogout
        case 13: self = .userSwitch
        case 14: self = .connectionFailed
        case 15: self = .sleep
        case 16: self = .appUpdate
        default: self = .other(rawValue)
        }
    }

    /// Short stable name for logs.
    public var logName: String {
        switch self {
        case .none: "none"
        case .userInitiated: "userInitiated"
        case .providerFailed: "providerFailed"
        case .noNetworkAvailable: "noNetworkAvailable"
        case .unrecoverableNetworkChange: "unrecoverableNetworkChange"
        case .providerDisabled: "providerDisabled"
        case .authenticationCanceled: "authenticationCanceled"
        case .configurationFailed: "configurationFailed"
        case .idleTimeout: "idleTimeout"
        case .configurationDisabled: "configurationDisabled"
        case .configurationRemoved: "configurationRemoved"
        case .superceded: "superceded"
        case .userLogout: "userLogout"
        case .userSwitch: "userSwitch"
        case .connectionFailed: "connectionFailed"
        case .sleep: "sleep"
        case .appUpdate: "appUpdate"
        case .other(let raw): "other(\(raw))"
        }
    }
}

public enum StopClassification: Sendable, Equatable {
    /// The user, or an app update, ended protection: stay quiet.
    case expected
    /// Protection ended without the user asking: notify.
    case unexpected
}

public enum StatusNotificationPolicy {
    /// Pure classification of a tunnel stop. A set user-off marker or a
    /// `.userInitiated` / `.appUpdate` reason is expected; everything else,
    /// including `.superceded` and `.providerFailed`, is unexpected.
    public static func classifyStop(
        reason: TunnelStopReason,
        userTurnedOffMarker: Bool
    ) -> StopClassification {
        if userTurnedOffMarker { return .expected }
        switch reason {
        case .userInitiated, .appUpdate: return .expected
        default: return .unexpected
        }
    }

    public static func shouldNotifyStop(reason: TunnelStopReason, userTurnedOffMarker: Bool) -> Bool {
        classifyStop(reason: reason, userTurnedOffMarker: userTurnedOffMarker) == .unexpected
    }
}

// MARK: - Decision engine

/// What happened, from the point of view of the notification policy.
public enum StatusNotificationEvent: Sendable, Equatable {
    /// A problem of this kind started (events 1, 2, 3, 7). Repeats while an
    /// episode is open are ignored.
    case problemStarted(StatusNotificationKind)
    /// The problem of this kind cleared (restore trigger for 1, 2, 3, 7).
    case problemCleared(StatusNotificationKind)
    /// `stopTunnel` ran: pending 1, 2, 6 and 7 end silently.
    case tunnelStopped
    /// The tunnel saw a pause deadline (`nil` when no pause is active).
    case pauseDeadline(Date?)
    /// A one-shot notification with no episode of its own (event 5; the
    /// caller tracks per-list episodes).
    case oneShot(StatusNotificationKind)
}

/// Episode and fire-time state the policy reads and returns, keyed by kind.
public struct StatusNotificationState: Sendable, Equatable {
    public var episodes: [StatusNotificationKind: NotificationEpisodeState]
    public var fireTimes: [StatusNotificationKind: [Date]]

    public init(
        episodes: [StatusNotificationKind: NotificationEpisodeState] = [:],
        fireTimes: [StatusNotificationKind: [Date]] = [:]
    ) {
        self.episodes = episodes
        self.fireTimes = fireTimes
    }

    public func episode(_ kind: StatusNotificationKind) -> NotificationEpisodeState {
        episodes[kind] ?? NotificationEpisodeState()
    }

    public func times(_ kind: StatusNotificationKind) -> [Date] {
        fireTimes[kind] ?? []
    }

    public static func load(from settings: SharedSettings) -> StatusNotificationState {
        var state = StatusNotificationState()
        for kind in StatusNotificationKind.allCases {
            state.episodes[kind] = settings.notificationEpisode(forKind: kind.rawValue)
            state.fireTimes[kind] = settings.notificationFireTimes(forKind: kind.rawValue)
        }
        return state
    }

    public func save(to settings: SharedSettings) {
        for kind in StatusNotificationKind.allCases {
            settings.setNotificationEpisode(episode(kind), forKind: kind.rawValue)
            settings.setNotificationFireTimes(times(kind), forKind: kind.rawValue)
        }
    }
}

/// Master switch plus per-type toggles, as the policy needs them.
public struct StatusNotificationPreferences: Sendable, Equatable {
    public var masterEnabled: Bool
    public var disabledTypes: Set<StatusNotificationKind.PreferenceType>

    public init(masterEnabled: Bool, disabledTypes: Set<StatusNotificationKind.PreferenceType> = []) {
        self.masterEnabled = masterEnabled
        self.disabledTypes = disabledTypes
    }

    public init(settings: SharedSettings) {
        var disabled = Set<StatusNotificationKind.PreferenceType>()
        let map: [(StatusNotificationKind.PreferenceType, NotificationType)] = [
            (.encryptedDNS, .dns), (.protectionStopped, .stopped),
            (.pauseEnded, .pause), (.blocklists, .lists),
        ]
        for (type, stored) in map where !settings.isNotificationTypeEnabled(stored) {
            disabled.insert(type)
        }
        self.init(masterEnabled: settings.notificationsEnabled, disabledTypes: disabled)
    }

    /// Why `kind` may not be notified, or nil when it may.
    public func blockReason(for kind: StatusNotificationKind) -> StatusNotificationSuppression.Reason? {
        if !masterEnabled { return .masterOff }
        if let type = kind.preferenceType, disabledTypes.contains(type) { return .typeDisabled }
        return nil
    }
}

public struct StatusNotificationSuppression: Sendable, Equatable {
    public enum Reason: String, Sendable, Equatable {
        case masterOff = "master off"
        case typeDisabled = "type disabled"
        case rateLimited = "rate-limited"
        case alreadyNotified = "already notified this episode"
    }

    public let kind: StatusNotificationKind
    public let reason: Reason
}

public enum StatusNotificationAction: Sendable, Equatable {
    /// Schedule `kind` to fire at `fireDate` (replaces any pending request
    /// with the same identifier).
    case schedule(StatusNotificationKind, fireDate: Date)
    /// Remove the pending request for `kind`. `clearedAfter` is how long the
    /// problem lasted, when known.
    case cancel(StatusNotificationKind, clearedAfter: TimeInterval?)
    /// Post the restore for the problem `kind`, replacing its notification.
    case postRestore(forKind: StatusNotificationKind)
}

/// Outcome of one policy evaluation. `actions` empty means "do nothing".
public struct StatusNotificationDecision: Sendable, Equatable {
    public var actions: [StatusNotificationAction] = []
    /// The state to persist after carrying out `actions`.
    public var state: StatusNotificationState
    /// Info-level log material: why something that could have been notified
    /// wasn't.
    public var suppressions: [StatusNotificationSuppression] = []
    /// Debug-level log material: inputs and outcome of each step. Contains
    /// only kinds, times and flags, never user data.
    public var trace: [String] = []
}

extension StatusNotificationPolicy {
    /// Pure decision: what to do for `event`, given the persisted `state`,
    /// the user's `preferences` and the clock value `now`.
    public static func decide(
        event: StatusNotificationEvent,
        state: StatusNotificationState,
        preferences: StatusNotificationPreferences,
        now: Date
    ) -> StatusNotificationDecision {
        var d = StatusNotificationDecision(state: state)
        d.trace.append("event \(event) master=\(preferences.masterEnabled) disabled=\(preferences.disabledTypes.map(\.rawValue).sorted()) now=\(now.timeIntervalSince1970)")
        switch event {
        case .problemStarted(let kind): problemStarted(kind, &d, preferences, now)
        case .problemCleared(let kind): problemCleared(kind, &d, preferences, now)
        case .tunnelStopped: tunnelStopped(&d, now)
        case .pauseDeadline(let date): pauseDeadline(date, &d, preferences, now)
        case .oneShot(let kind): oneShot(kind, &d, preferences, now)
        }
        d.trace.append("outcome actions=\(d.actions) suppressed=\(d.suppressions.map { "\($0.kind.rawValue): \($0.reason.rawValue)" })")
        return d
    }

    /// Delivered: the fire time passed and the request wasn't removed
    /// (removal clears `scheduledFireTime`).
    public static func isDelivered(_ episode: NotificationEpisodeState, now: Date) -> Bool {
        guard episode.isOpen, let fire = episode.scheduledFireTime else { return false }
        return fire <= now
    }

    // MARK: Steps

    private static func problemStarted(
        _ kind: StatusNotificationKind,
        _ d: inout StatusNotificationDecision,
        _ prefs: StatusNotificationPreferences,
        _ now: Date
    ) {
        // 1 <-> 2 is a new problem, not a restore: end the sibling silently.
        if let sibling = resolverSibling(of: kind), d.state.episode(sibling).isOpen {
            endSilently(sibling, &d, now, reason: "kind change to \(kind.rawValue)")
        }
        if d.state.episode(kind).isOpen {
            d.suppressions.append(.init(kind: kind, reason: .alreadyNotified))
            d.trace.append("\(kind.rawValue): episode already open")
            return
        }
        if let reason = prefs.blockReason(for: kind) {
            d.suppressions.append(.init(kind: kind, reason: reason))
            return
        }
        let fire = now.addingTimeInterval(kind.debounceDelay)
        // The episode opens even when rate limited, so no restore follows.
        if rateLimited(kind, fire: fire, state: d.state) {
            d.state.episodes[kind] = NotificationEpisodeState(isOpen: true, scheduledFireTime: nil, notified: false)
            d.suppressions.append(.init(kind: kind, reason: .rateLimited))
            return
        }
        d.state.episodes[kind] = NotificationEpisodeState(isOpen: true, scheduledFireTime: fire, notified: false)
        record(fire, for: kind, &d.state, now: now)
        d.actions.append(.schedule(kind, fireDate: fire))
    }

    private static func problemCleared(
        _ kind: StatusNotificationKind,
        _ d: inout StatusNotificationDecision,
        _ prefs: StatusNotificationPreferences,
        _ now: Date
    ) {
        let episode = d.state.episode(kind)
        guard episode.isOpen else {
            d.trace.append("\(kind.rawValue): no open episode")
            return
        }
        d.state.episodes[kind] = NotificationEpisodeState()
        guard isDelivered(episode, now: now) else {
            // Not delivered: drop the pending request (if any), no restore.
            if episode.scheduledFireTime != nil {
                d.actions.append(.cancel(kind, clearedAfter: elapsed(kind, episode, now)))
                removeFireTime(episode.scheduledFireTime, for: kind, &d.state)
            }
            return
        }
        if let reason = prefs.blockReason(for: kind) {
            d.suppressions.append(.init(kind: .restored, reason: reason))
            return
        }
        let restoreFire = now
        if rateLimited(.restored, fire: restoreFire, state: d.state) {
            d.suppressions.append(.init(kind: .restored, reason: .rateLimited))
            return
        }
        record(restoreFire, for: .restored, &d.state, now: now)
        d.actions.append(.postRestore(forKind: kind))
    }

    private static func tunnelStopped(_ d: inout StatusNotificationDecision, _ now: Date) {
        for kind in [StatusNotificationKind.resolverFallback, .resolverFailing, .pauseEnded, .degraded]
        where d.state.episode(kind).isOpen {
            endSilently(kind, &d, now, reason: "tunnel stopped")
        }
    }

    private static func pauseDeadline(
        _ date: Date?,
        _ d: inout StatusNotificationDecision,
        _ prefs: StatusNotificationPreferences,
        _ now: Date
    ) {
        let kind = StatusNotificationKind.pauseEnded
        let episode = d.state.episode(kind)
        let pending = episode.isOpen && !isDelivered(episode, now: now) && episode.scheduledFireTime != nil
        guard let date, date > now else {
            // Pause cleared or shortened to the past: drop a pending request.
            if pending { endSilently(kind, &d, now, reason: "pause cleared") }
            return
        }
        if pending, episode.scheduledFireTime == date {
            d.trace.append("pause-ended: deadline unchanged")
            return
        }
        if let reason = prefs.blockReason(for: kind) {
            if pending { endSilently(kind, &d, now, reason: "pause notifications disabled") }
            d.suppressions.append(.init(kind: kind, reason: reason))
            return
        }
        // A changed deadline replaces the pending request (same identifier).
        if pending { removeFireTime(episode.scheduledFireTime, for: kind, &d.state) }
        if rateLimited(kind, fire: date, state: d.state) {
            if pending { d.actions.append(.cancel(kind, clearedAfter: nil)) }
            d.state.episodes[kind] = NotificationEpisodeState(isOpen: true, scheduledFireTime: nil, notified: false)
            d.suppressions.append(.init(kind: kind, reason: .rateLimited))
            return
        }
        d.state.episodes[kind] = NotificationEpisodeState(isOpen: true, scheduledFireTime: date, notified: false)
        record(date, for: kind, &d.state, now: now)
        d.actions.append(.schedule(kind, fireDate: date))
    }

    private static func oneShot(
        _ kind: StatusNotificationKind,
        _ d: inout StatusNotificationDecision,
        _ prefs: StatusNotificationPreferences,
        _ now: Date
    ) {
        if let reason = prefs.blockReason(for: kind) {
            d.suppressions.append(.init(kind: kind, reason: reason))
            return
        }
        let fire = now.addingTimeInterval(kind.debounceDelay)
        if rateLimited(kind, fire: fire, state: d.state) {
            d.suppressions.append(.init(kind: kind, reason: .rateLimited))
            return
        }
        record(fire, for: kind, &d.state, now: now)
        d.actions.append(.schedule(kind, fireDate: fire))
    }

    // MARK: Helpers

    private static func resolverSibling(of kind: StatusNotificationKind) -> StatusNotificationKind? {
        switch kind {
        case .resolverFallback: .resolverFailing
        case .resolverFailing: .resolverFallback
        default: nil
        }
    }

    /// Close `kind`'s episode with no restore, removing its pending request.
    private static func endSilently(
        _ kind: StatusNotificationKind,
        _ d: inout StatusNotificationDecision,
        _ now: Date,
        reason: String
    ) {
        let episode = d.state.episode(kind)
        d.state.episodes[kind] = NotificationEpisodeState()
        d.trace.append("\(kind.rawValue): episode ended silently (\(reason))")
        if let fire = episode.scheduledFireTime, fire > now {
            d.actions.append(.cancel(kind, clearedAfter: elapsed(kind, episode, now)))
            removeFireTime(fire, for: kind, &d.state)
        }
    }

    private static func elapsed(
        _ kind: StatusNotificationKind,
        _ episode: NotificationEpisodeState,
        _ now: Date
    ) -> TimeInterval? {
        guard let fire = episode.scheduledFireTime else { return nil }
        return max(0, now.timeIntervalSince(fire.addingTimeInterval(-kind.debounceDelay)))
    }

    /// Would posting `kind` at `fire` come within the rate-limit window of a
    /// fire time already recorded for that kind?
    private static func rateLimited(
        _ kind: StatusNotificationKind,
        fire: Date,
        state: StatusNotificationState
    ) -> Bool {
        state.times(kind).contains { abs($0.timeIntervalSince(fire)) < StatusNotificationKind.rateLimitInterval }
    }

    private static func record(
        _ fire: Date,
        for kind: StatusNotificationKind,
        _ state: inout StatusNotificationState,
        now: Date
    ) {
        let horizon = now.addingTimeInterval(-StatusNotificationKind.rateLimitInterval)
        var times = state.times(kind).filter { $0 > horizon }
        times.append(fire)
        state.fireTimes[kind] = times
    }

    private static func removeFireTime(
        _ fire: Date?,
        for kind: StatusNotificationKind,
        _ state: inout StatusNotificationState
    ) {
        guard let fire else { return }
        var times = state.times(kind)
        if let i = times.firstIndex(of: fire) { times.remove(at: i) }
        state.fireTimes[kind] = times
    }
}
