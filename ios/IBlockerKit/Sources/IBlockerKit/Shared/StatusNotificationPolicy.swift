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
