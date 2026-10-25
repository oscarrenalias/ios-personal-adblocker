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
        public static let settingsAvailableSentinel = "settingsAvailableSentinel"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    #if canImport(Darwin)
    public init?(groupID: String) {
        guard let defaults = UserDefaults(suiteName: groupID) else { return nil }
        self.init(defaults: defaults)
    }
    #endif

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
        }
    }

    /// Mirror of the tunnel's connected state, written by the provider and
    /// the VPN control helper so widgets and the Control Center toggle can
    /// show the right state without loading the VPN manager.
    public var protectionActive: Bool {
        get { defaults.bool(forKey: Keys.protectionActive) }
        nonmutating set { defaults.set(newValue, forKey: Keys.protectionActive) }
    }
}
