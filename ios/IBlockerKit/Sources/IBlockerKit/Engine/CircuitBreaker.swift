import Foundation

/// Tracks whether an alternative resolver is usable.
///
/// Healthy until `failureThreshold` consecutive failures, then down until
/// `nextProbeAt`, after which callers may probe it. Results are tagged with the
/// generation current when the request started; results from an older
/// generation (a trip or reset happened since) are ignored. A failure counts
/// only if its request started at or after the last counted failure, so a burst
/// of requests stalled on one connection counts once.
public struct CircuitBreaker: Sendable {
    public enum State: Equatable, Sendable {
        case healthy(consecutiveFailures: Int)
        case down(nextProbeAt: Date, backoff: TimeInterval, since: Date)
    }

    public static let defaultFailureThreshold = 3
    public static let defaultBackoff: TimeInterval = 5
    public static let maxBackoff: TimeInterval = 300

    private static let log = Log(category: "router")

    public private(set) var state: State = .healthy(consecutiveFailures: 0)
    /// Increments on every trip and every reset.
    public private(set) var generation: Int = 0

    /// A probe has been handed out and its result is not in yet.
    private var probeInFlight = false
    private var probeStartedAt: Date?
    /// A network change asked for an immediate probe regardless of state.
    private var immediateProbePending = false
    /// When the most recent counted failure happened; nil after success, trip or reset.
    private var lastCountedFailureAt: Date?

    private let name: String
    private let effect: String
    private let failureThreshold: Int
    private let initialBackoff: TimeInterval
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - name: alternative resolver name, used in log messages.
    ///   - effect: what tripping means for queries, used in log messages.
    public init(
        name: String,
        effect: String,
        failureThreshold: Int = CircuitBreaker.defaultFailureThreshold,
        backoff: TimeInterval = CircuitBreaker.defaultBackoff,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.name = name
        self.effect = effect
        self.failureThreshold = failureThreshold
        self.initialBackoff = backoff
        self.now = now
    }

    public var isDown: Bool {
        if case .down = state { return true }
        return false
    }

    /// True when the alternative may be used: healthy, or down with the probe time reached.
    public var isAvailable: Bool {
        switch state {
        case .healthy: return true
        case .down(let nextProbeAt, _, _): return now() >= nextProbeAt
        }
    }

    /// Returns true when the caller should start a probe now, and marks it in flight.
    /// Exactly one probe runs at a time: down with `now >= nextProbeAt`, or an
    /// immediate probe requested by `networkChange()`. The caller tags the probe
    /// result with `generation` as read right after this returns true.
    public mutating func probeDue(_ now: Date) -> Bool {
        guard !probeInFlight else { return false }
        let due: Bool
        if immediateProbePending {
            due = true
        } else if case .down(let nextProbeAt, _, _) = state {
            due = now >= nextProbeAt
        } else {
            due = false
        }
        guard due else { return false }
        immediateProbePending = false
        probeInFlight = true
        probeStartedAt = now
        Self.log.info("probe of alternative resolver \(name) started")
        return true
    }

    /// Records a successful probe. Ignored if the generation is stale.
    public mutating func probeSucceeded(generation: Int) {
        guard generation == self.generation else { return }
        logProbeEnd("succeeded", error: nil)
        probeInFlight = false
        recordSuccess(generation: generation)
    }

    /// Records a failed probe. Ignored if the generation is stale.
    public mutating func probeFailed(generation: Int, error: String) {
        guard generation == self.generation else { return }
        probeInFlight = false
        recordFailure(generation: generation)
        logProbeEnd("failed", error: error)
    }

    /// The network changed: forget past failures, drop any in-flight probe result
    /// and request one immediate probe. That probe's failure counts as a single
    /// failure, so it cannot trip the breaker on its own. The router only calls
    /// this when the alternative is enabled.
    public mutating func networkChange() {
        generation += 1
        state = .healthy(consecutiveFailures: 0)
        probeInFlight = false
        probeStartedAt = nil
        lastCountedFailureAt = nil
        immediateProbePending = true
        Self.log.info("alternative resolver \(name) breaker reset by network change (generation \(generation))")
    }

    private mutating func logProbeEnd(_ outcome: String, error: String?) {
        let duration = probeStartedAt.map { now().timeIntervalSince($0) } ?? 0
        probeStartedAt = nil
        var message = "probe of alternative resolver \(name) \(outcome) after \(Int((duration * 1000).rounded())) ms"
        if let error { message += ": \(error)" }
        if case .down(let nextProbeAt, _, _) = state {
            let wait = max(0, nextProbeAt.timeIntervalSince(now()))
            message += "; next probe in \(Int(wait.rounded())) s"
        }
        Self.log.info(message)
    }

    public mutating func recordSuccess(generation: Int) {
        guard generation == self.generation else { return }
        switch state {
        case .healthy(let failures):
            lastCountedFailureAt = nil
            if failures != 0 { state = .healthy(consecutiveFailures: 0) }
        case .down(_, _, let since):
            self.generation += 1
            lastCountedFailureAt = nil
            state = .healthy(consecutiveFailures: 0)
            let downFor = now().timeIntervalSince(since)
            Self.log.notice("alternative resolver \(name) recovered after \(Int(downFor.rounded())) s down")
        }
    }

    /// - Parameter startedAt: when the failed request started. A failure whose request
    ///   started before the last counted failure is part of the same burst and is not counted.
    public mutating func recordFailure(generation: Int, startedAt: Date? = nil) {
        guard generation == self.generation else { return }
        switch state {
        case .healthy(let failures):
            if let startedAt, let last = lastCountedFailureAt, startedAt < last {
                Self.log.debug("failure not counted: request started before last counted failure")
                return
            }
            lastCountedFailureAt = now()
            let count = failures + 1
            if count >= failureThreshold {
                trip(backoff: initialBackoff, since: now(), failures: count)
            } else {
                state = .healthy(consecutiveFailures: count)
            }
        case .down(_, let backoff, let since):
            // A failed probe: stay down with a longer backoff.
            trip(backoff: min(backoff * 2, Self.maxBackoff), since: since, failures: 1)
        }
    }

    private mutating func trip(backoff: TimeInterval, since: Date, failures: Int) {
        generation += 1
        lastCountedFailureAt = nil
        state = .down(nextProbeAt: now().addingTimeInterval(backoff), backoff: backoff, since: since)
        Self.log.notice("alternative resolver \(name) marked down after \(failures) failure(s), retry in \(Int(backoff)) s; \(effect)")
    }
}
