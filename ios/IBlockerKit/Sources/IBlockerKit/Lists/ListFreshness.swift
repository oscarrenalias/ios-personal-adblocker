import Foundation

/// Decides whether a filter list's last accepted update is too old.
/// Pure: `now` is injected so tests don't depend on the wall clock.
public enum ListFreshness {

    /// A list is stale only when strictly more than this many seconds old.
    public static let staleThreshold: TimeInterval = 7 * 24 * 60 * 60

    /// True when `lastAccepted` is strictly more than 7 days before `now`.
    /// Exactly 7 days (or less, or a future date) is fresh. A nil
    /// `lastAccepted` (never updated, e.g. bundled-only) is not stale:
    /// there is no update age to judge.
    public static func isStale(lastAccepted: Date?, now: Date, threshold: TimeInterval = staleThreshold) -> Bool {
        guard let lastAccepted else { return false }
        return now.timeIntervalSince(lastAccepted) > threshold
    }
}
