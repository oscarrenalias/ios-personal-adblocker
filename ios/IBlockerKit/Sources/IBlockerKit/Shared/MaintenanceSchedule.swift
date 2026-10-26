import Foundation

/// Decides what a tunnel maintenance pass does and when the next timer wake
/// happens. Pure state machine: the caller owns the clock and the sleeping.
///
/// - Idle passes run every `idleInterval`, degraded ones every `degradedInterval`.
/// - Only timer passes move the deadline and advance the degraded tick counter;
///   signal passes (settings/blocklist notifications) run their steps and leave both alone.
/// - Switching between degraded and idle recomputes the deadline from `now`.
/// - A pending verbose-logging expiry (plus `verboseMargin`) shortens the next
///   wake so the flag is switched off promptly.
public struct MaintenanceSchedule: Equatable, Sendable {
    public static let idleInterval: TimeInterval = 60
    public static let degradedInterval: TimeInterval = 2
    /// Every Nth degraded timer tick also checks the blocklist file.
    public static let blocklistCheckEvery = 5
    /// Slack added after `verboseLoggingUntil` so the wake lands just past expiry.
    public static let verboseMargin: TimeInterval = 1

    public enum WakeReason: Equatable, Sendable {
        case timer
        case settings
        case blocklist
    }

    public enum Step: Equatable, Sendable {
        case flush
        case settings
        case recovery
        case blocklistCheck
    }

    public struct Plan: Equatable, Sendable {
        public let steps: [Step]
        /// When the next timer wake is due (already shortened for verbose expiry).
        public let nextWake: Date
        /// `nextWake - now`, never negative.
        public let interval: TimeInterval
    }

    public private(set) var degraded: Bool
    public private(set) var tick: Int
    /// Timer deadline without the verbose shortening.
    public private(set) var deadline: Date

    public init(degraded: Bool, now: Date) {
        self.degraded = degraded
        self.tick = 0
        self.deadline = now.addingTimeInterval(Self.interval(degraded: degraded))
    }

    public static func interval(degraded: Bool) -> TimeInterval {
        degraded ? degradedInterval : idleInterval
    }

    /// Plans one pass. `degraded` is the current recovery state; a change from
    /// the previous pass resets the tick counter and the deadline.
    public mutating func plan(
        reason: WakeReason,
        degraded isDegraded: Bool,
        now: Date,
        verboseLoggingUntil: Date? = nil
    ) -> Plan {
        if isDegraded != degraded {
            degraded = isDegraded
            tick = 0
            deadline = now.addingTimeInterval(Self.interval(degraded: isDegraded))
        }

        var steps: [Step]
        switch reason {
        case .timer:
            steps = [.flush, .settings]
            if degraded { steps.append(.recovery) }
            tick += 1
            if !degraded || tick % Self.blocklistCheckEvery == 0 {
                steps.append(.blocklistCheck)
            }
            deadline = now.addingTimeInterval(Self.interval(degraded: degraded))
        case .settings:
            steps = [.settings]
            if degraded { steps.append(.recovery) }
        case .blocklist:
            steps = [.blocklistCheck]
        }

        let next = wake(now: now, verboseLoggingUntil: verboseLoggingUntil)
        return Plan(steps: steps, nextWake: next, interval: max(0, next.timeIntervalSince(now)))
    }

    /// Next timer wake: the deadline, or the verbose expiry if that comes first.
    public func wake(now: Date, verboseLoggingUntil: Date?) -> Date {
        guard let until = verboseLoggingUntil else { return deadline }
        let verboseWake = until.addingTimeInterval(Self.verboseMargin)
        return verboseWake > now && verboseWake < deadline ? verboseWake : deadline
    }
}
