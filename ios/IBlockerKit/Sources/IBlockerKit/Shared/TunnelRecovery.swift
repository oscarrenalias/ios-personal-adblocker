import Foundation

/// Decides what the tunnel must retry while it runs degraded, i.e. started
/// before first unlock with unreadable settings and/or blocklist blobs.
/// Pure so it is unit-testable; the provider performs the actual work.
public struct TunnelRecovery: Sendable, Equatable {
    public struct Actions: Sendable, Equatable {
        /// Re-apply upstream, query-log setting, pause and verbose.
        public var reapplySettings = false
        /// Reload the matcher from disk.
        public var reloadMatcher = false

        public init(reapplySettings: Bool = false, reloadMatcher: Bool = false) {
            self.reapplySettings = reapplySettings
            self.reloadMatcher = reloadMatcher
        }
    }

    public private(set) var settingsPending: Bool
    public private(set) var blocklistPending: Bool

    public init(settingsReadable: Bool, blocklistLoaded: Bool) {
        settingsPending = !settingsReadable
        blocklistPending = !blocklistLoaded
    }

    /// True while the provider should keep probing on every maintenance tick.
    public var isDegraded: Bool { settingsPending || blocklistPending }

    /// Feed the current observations; returns the work to do now. A part
    /// leaves the pending set the moment it is reported readable.
    public mutating func tick(settingsReadable: Bool, blocklistReadable: Bool) -> Actions {
        var actions = Actions()
        if settingsPending && settingsReadable {
            settingsPending = false
            actions.reapplySettings = true
        }
        if blocklistPending && blocklistReadable {
            blocklistPending = false
            actions.reloadMatcher = true
        }
        return actions
    }
}

/// Allows each distinct message through at most once per interval, so a
/// failure that repeats every tick doesn't flood the log.
public struct ErrorLogLimiter: Sendable {
    public let interval: TimeInterval
    private var lastLogged: [String: Date] = [:]

    public init(interval: TimeInterval = 60) {
        self.interval = interval
    }

    public mutating func shouldLog(_ key: String, now: Date = Date()) -> Bool {
        if let last = lastLogged[key], now.timeIntervalSince(last) < interval { return false }
        lastLogged[key] = now
        return true
    }
}
