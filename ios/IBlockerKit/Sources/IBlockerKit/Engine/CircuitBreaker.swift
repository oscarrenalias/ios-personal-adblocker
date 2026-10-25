import Foundation

/// Tracks whether an alternative resolver is usable.
///
/// Healthy until `failureThreshold` consecutive failures, then down until
/// `nextProbeAt`, after which callers may probe it. Results are tagged with the
/// generation current when the request started; results from an older
/// generation (a trip or reset happened since) are ignored.
public struct CircuitBreaker: Sendable {
    public enum State: Equatable, Sendable {
        case healthy(consecutiveFailures: Int)
        case down(nextProbeAt: Date, backoff: TimeInterval, since: Date)
    }

    public static let defaultFailureThreshold = 3
    public static let defaultBackoff: TimeInterval = 30
    public static let maxBackoff: TimeInterval = 300

    private static let log = Log(category: "router")

    public private(set) var state: State = .healthy(consecutiveFailures: 0)
    /// Increments on every trip and every reset.
    public private(set) var generation: Int = 0

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

    public mutating func recordSuccess(generation: Int) {
        guard generation == self.generation else { return }
        switch state {
        case .healthy(let failures):
            if failures != 0 { state = .healthy(consecutiveFailures: 0) }
        case .down(_, _, let since):
            self.generation += 1
            state = .healthy(consecutiveFailures: 0)
            let downFor = now().timeIntervalSince(since)
            Self.log.notice("alternative resolver \(name) recovered after \(Int(downFor.rounded())) s down")
        }
    }

    public mutating func recordFailure(generation: Int) {
        guard generation == self.generation else { return }
        switch state {
        case .healthy(let failures):
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
        state = .down(nextProbeAt: now().addingTimeInterval(backoff), backoff: backoff, since: since)
        Self.log.notice("alternative resolver \(name) marked down after \(failures) failure(s), retry in \(Int(backoff)) s; \(effect)")
    }
}
