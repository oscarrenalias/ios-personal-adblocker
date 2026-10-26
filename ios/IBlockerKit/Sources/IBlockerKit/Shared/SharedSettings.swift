import Foundation

/// How the tunnel deals with Apple's relay (Private Relay + "Limit IP
/// Address Tracking"), which can carry tracker traffic past any DNS filter.
public enum RelayStrategy: String, CaseIterable, Sendable {
    /// DNS-block the relay endpoints (strongest; Private Relay unavailable
    /// while protection is on).
    case blockDomains
    /// Touch nothing Apple; the user turns off "Limit IP Address Tracking"
    /// per network instead. Private Relay keeps working.
    case keepRelay
    /// Present the tunnel as a full VPN so iOS suspends the relay by itself
    /// while protection runs — the approach commercial blockers use. The
    /// relay returns automatically when protection stops.
    case autoSuspend
}

/// What the router does when the chosen upstream can't answer a query.
public enum FallbackPolicy: String, Codable, CaseIterable, Sendable, Equatable {
    /// Retry via the current network's own DNS.
    case networkDNS
    /// Don't fall back; the query fails.
    case none
}

/// User's resolver choice: network DNS by default, optionally an alternative
/// encrypted resolver, plus what to do when that resolver fails.
public struct ResolverSettings: Codable, Sendable, Equatable {
    public var useAlternative: Bool
    public var alternative: UpstreamConfig
    public var alternativeName: String
    public var fallbackPolicy: FallbackPolicy

    public init(
        useAlternative: Bool,
        alternative: UpstreamConfig,
        alternativeName: String,
        fallbackPolicy: FallbackPolicy
    ) {
        self.useAlternative = useAlternative
        self.alternative = alternative
        self.alternativeName = alternativeName
        self.fallbackPolicy = fallbackPolicy
    }

    /// Alternative off; Cloudflare DoH preselected for when it is enabled.
    public static let `default` = ResolverSettings(
        useAlternative: false,
        alternative: UpstreamConfig(kind: .doh, dohURL: "https://1.1.1.1/dns-query"),
        alternativeName: "Cloudflare",
        fallbackPolicy: .networkDNS
    )
}

/// Typed accessors over the App Group's shared UserDefaults.
/// UserDefaults is documented thread-safe, hence the unchecked conformance.
public struct SharedSettings: @unchecked Sendable {
    public enum Keys {
        public static let upstreamConfig = "upstreamConfig"
        public static let resolverSettings = "resolverSettings"
        public static let onboardingComplete = "onboardingComplete"
        public static let queryLogEnabled = "queryLogEnabled"
        public static let lastListUpdate = "lastListUpdate"
        public static let relayStrategy = "relayStrategy"
        public static let pausedUntil = "pausedUntil"
        public static let protectionActive = "protectionActive"
        public static let verboseLoggingUntil = "verboseLoggingUntil"
        public static let widgetResolverStatus = "widgetResolverStatus"
        public static let settingsAvailableSentinel = "settingsAvailableSentinel"
        public static let notificationsEnabled = "notificationsEnabled"
        /// Per-type toggles are stored under this prefix + `NotificationType.rawValue`.
        public static let notificationTypePrefix = "notificationType."
        public static let userTurnedOff = "userTurnedOff"
        public static let notificationEpisodes = "notificationEpisodes"
        public static let notificationFireTimes = "notificationFireTimes"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public init?(groupID: String) {
        guard let defaults = UserDefaults(suiteName: groupID) else { return nil }
        self.init(defaults: defaults)
    }

    /// Written by the app at every launch. The tunnel can start before the
    /// first unlock, when the shared defaults are unreadable and every key
    /// reads as unset; a missing sentinel means "not readable yet".
    public var settingsAvailable: Bool {
        get { defaults.bool(forKey: Keys.settingsAvailableSentinel) }
        nonmutating set { defaults.set(newValue, forKey: Keys.settingsAvailableSentinel) }
    }

    public var upstreamConfig: UpstreamConfig {
        get {
            guard let data = defaults.data(forKey: Keys.upstreamConfig),
                  let config = try? JSONDecoder().decode(UpstreamConfig.self, from: data) else {
                return .default
            }
            return config
        }
        nonmutating set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.upstreamConfig)
            }
        }
    }

    /// The user's resolver choice. When `resolverSettings` has never been
    /// written, it is derived from the legacy `upstreamConfig` on read; nothing
    /// is written back and `upstreamConfig` is left untouched.
    public var resolverSettings: ResolverSettings {
        get {
            if let data = defaults.data(forKey: Keys.resolverSettings),
               let settings = try? JSONDecoder().decode(ResolverSettings.self, from: data) {
                return Self.migratingOldQuad9(settings)
            }
            return Self.migratingOldQuad9(migratedResolverSettings())
        }
        nonmutating set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.resolverSettings)
            }
        }
    }

    /// Former Quad9 DoH endpoint (non-standard port). Read-time migration only.
    private static let oldQuad9DoHURL = "https://9.9.9.9:5053/dns-query"

    /// Swaps the old Quad9 DoH alternative for the current Quad9 preset on
    /// read; other fields and other URLs are left alone, nothing is written.
    private static func migratingOldQuad9(_ settings: ResolverSettings) -> ResolverSettings {
        guard settings.alternative.kind == .doh,
              settings.alternative.dohURL == oldQuad9DoHURL else { return settings }
        var migrated = settings
        if quad9Logged.claim() {
            log.notice(
                "replaced old Quad9 URL \(oldQuad9DoHURL) -> \(UpstreamPreset.quad9.config.dohURL ?? "")")
        }
        migrated.alternative = UpstreamPreset.quad9.config
        migrated.alternativeName = UpstreamPreset.quad9.name
        return migrated
    }

    private func migratedResolverSettings() -> ResolverSettings {
        let old = upstreamConfig
        let derived: ResolverSettings
        switch old.kind {
        case .network:
            derived = .default
        case .doh, .udp:
            derived = ResolverSettings(
                useAlternative: true,
                alternative: old,
                alternativeName: UpstreamPreset.name(for: old),
                fallbackPolicy: .networkDNS)
        }
        if Self.migrationLogged.claim() {
            Self.log.notice(
                "resolver settings derived from legacy upstream (old kind \(old.kind.rawValue)): useAlternative=\(derived.useAlternative) alternative=\(derived.alternativeName) fallback=\(derived.fallbackPolicy.rawValue)")
        }
        return derived
    }

    private static let log = Log(category: "settings")
    /// Reads happen on every tunnel tick; log the derivation once per process.
    private static let migrationLogged = OnceFlag()
    private static let quad9Logged = OnceFlag()

    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    public var onboardingComplete: Bool {
        get { defaults.bool(forKey: Keys.onboardingComplete) }
        nonmutating set { defaults.set(newValue, forKey: Keys.onboardingComplete) }
    }

    public var queryLogEnabled: Bool {
        get { defaults.object(forKey: Keys.queryLogEnabled) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Keys.queryLogEnabled) }
    }

    public var lastListUpdate: Date? {
        get { defaults.object(forKey: Keys.lastListUpdate) as? Date }
        nonmutating set { defaults.set(newValue, forKey: Keys.lastListUpdate) }
    }

    public var relayStrategy: RelayStrategy {
        get {
            guard let raw = defaults.string(forKey: Keys.relayStrategy),
                  let strategy = RelayStrategy(rawValue: raw) else { return .blockDomains }
            return strategy
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Keys.relayStrategy) }
    }

    /// What the tunnel should actually apply. While the relay UI is hidden a
    /// stored choice can't be changed back, so it reports the neutral default
    /// and leaves the stored value untouched. See `FeatureFlags`.
    public var effectiveRelayStrategy: RelayStrategy {
        FeatureFlags.showAppleRelayControls ? relayStrategy : .blockDomains
    }

    /// When set to a future instant, the tunnel forwards everything without
    /// blocking (a temporary "let this through" for a broken checkout,
    /// captcha, or link). Any process — app, widget, App Intent — can write
    /// it; the tunnel re-reads it on its maintenance tick.
    public var pausedUntil: Date? {
        get {
            let t = defaults.double(forKey: Keys.pausedUntil)
            guard t > 0 else { return nil }
            let date = Date(timeIntervalSince1970: t)
            return date > Date() ? date : nil
        }
        nonmutating set {
            defaults.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Keys.pausedUntil)
            TunnelSignal.post(.settingsChanged)
        }
    }

    /// While in the future, `Log.debug` messages are also emitted at info
    /// level (prefixed `[verbose]`) so they show in Console.app without a
    /// logging profile. A past date reads as nil.
    public var verboseLoggingUntil: Date? {
        get {
            let t = defaults.double(forKey: Keys.verboseLoggingUntil)
            guard t > 0 else { return nil }
            let date = Date(timeIntervalSince1970: t)
            return date > Date() ? date : nil
        }
        nonmutating set {
            defaults.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Keys.verboseLoggingUntil)
            TunnelSignal.post(.settingsChanged)
        }
    }

    /// Mirror of the tunnel's connected state, written by the provider and
    /// the VPN control helper so widgets and the Control Center toggle can
    /// show the right state without loading the VPN manager.
    public var protectionActive: Bool {
        get { defaults.bool(forKey: Keys.protectionActive) }
        nonmutating set { defaults.set(newValue, forKey: Keys.protectionActive) }
    }

    /// Mirror of the tunnel's resolver status for widgets, stored as JSON.
    /// Reads as nil when missing or undecodable. Prefer
    /// `writeWidgetResolverStatus(_:)` where an encode failure must be seen;
    /// this setter drops it.
    public var widgetResolverStatus: ResolverStatus? {
        get {
            guard let data = defaults.data(forKey: Keys.widgetResolverStatus) else { return nil }
            return try? JSONDecoder().decode(ResolverStatus.self, from: data)
        }
        nonmutating set { try? writeWidgetResolverStatus(newValue) }
    }

    /// Stores `status` (nil removes the key). Throws the encoding error so the
    /// caller, e.g. the tunnel, can log it; nothing is written on failure.
    public func writeWidgetResolverStatus(_ status: ResolverStatus?) throws {
        guard let status else {
            defaults.removeObject(forKey: Keys.widgetResolverStatus)
            return
        }
        defaults.set(try JSONEncoder().encode(status), forKey: Keys.widgetResolverStatus)
    }

    // MARK: - Status notifications

    /// Master switch for status notifications. Off until the user turns it on.
    public var notificationsEnabled: Bool {
        get { defaults.object(forKey: Keys.notificationsEnabled) as? Bool ?? false }
        nonmutating set { defaults.set(newValue, forKey: Keys.notificationsEnabled) }
    }

    /// Whether notifications of `type` are wanted (default on). The master
    /// switch is separate; posters check both.
    public func isNotificationTypeEnabled(_ type: NotificationType) -> Bool {
        defaults.object(forKey: Keys.notificationTypePrefix + type.rawValue) as? Bool ?? true
    }

    public func setNotificationType(_ type: NotificationType, enabled: Bool) {
        defaults.set(enabled, forKey: Keys.notificationTypePrefix + type.rawValue)
    }

    /// The user's intent to have protection off, set by every off path before
    /// it stops the tunnel and cleared by every on path. Deliberately separate
    /// from `protectionActive`, which mirrors tunnel state and is cleared by
    /// the tunnel on every stop. Unset by default.
    public var userTurnedOff: Bool {
        get { defaults.bool(forKey: Keys.userTurnedOff) }
        nonmutating set { defaults.set(newValue, forKey: Keys.userTurnedOff) }
    }

    /// Episode state for a notification kind (`kind` is the kind's stable
    /// string key). Returns a closed, empty episode when none is stored.
    public func notificationEpisode(forKind kind: String) -> NotificationEpisodeState {
        notificationEpisodes[kind] ?? NotificationEpisodeState()
    }

    public func setNotificationEpisode(_ episode: NotificationEpisodeState, forKind kind: String) {
        var all = notificationEpisodes
        all[kind] = episode
        notificationEpisodes = all
    }

    /// Fire times recorded for a kind, used for the per-kind rate limit.
    public func notificationFireTimes(forKind kind: String) -> [Date] {
        notificationFireTimesByKind[kind] ?? []
    }

    public func setNotificationFireTimes(_ times: [Date], forKind kind: String) {
        var all = notificationFireTimesByKind
        all[kind] = times
        notificationFireTimesByKind = all
    }

    private var notificationEpisodes: [String: NotificationEpisodeState] {
        get {
            guard let data = defaults.data(forKey: Keys.notificationEpisodes),
                  let decoded = try? JSONDecoder().decode([String: NotificationEpisodeState].self, from: data)
            else { return [:] }
            return decoded
        }
        nonmutating set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.notificationEpisodes)
            }
        }
    }

    private var notificationFireTimesByKind: [String: [Date]] {
        get {
            guard let data = defaults.data(forKey: Keys.notificationFireTimes),
                  let decoded = try? JSONDecoder().decode([String: [Date]].self, from: data)
            else { return [:] }
            return decoded
        }
        nonmutating set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.notificationFireTimes)
            }
        }
    }
}

/// The four user-facing notification toggles.
public enum NotificationType: String, CaseIterable, Sendable {
    /// Encrypted DNS fallback/failure and restores.
    case dns
    /// Protection stopped, built-in rules only, and restores.
    case stopped
    /// Pause ended.
    case pause
    /// Blocklist rejections and staleness.
    case lists
}

/// Persisted state of one notification kind's problem episode.
public struct NotificationEpisodeState: Codable, Sendable, Equatable {
    /// A problem episode is in progress (no restore has closed it yet).
    public var isOpen: Bool
    /// When the pending notification is (or was) scheduled to fire.
    public var scheduledFireTime: Date?
    /// The notification was delivered (fire time passed, request not removed).
    public var notified: Bool

    public init(isOpen: Bool = false, scheduledFireTime: Date? = nil, notified: Bool = false) {
        self.isOpen = isOpen
        self.scheduledFireTime = scheduledFireTime
        self.notified = notified
    }
}
