import Foundation

/// Computes the pause deadline for a Control Center pause button.
public enum PauseDeadline {
    public enum Result: Equatable {
        /// Protection is off; nothing to pause.
        case noop
        /// Pause until `deadline`. `replacedExisting` is true when a still-running pause is overwritten.
        case pause(deadline: Date, replacedExisting: Bool)

        public var deadline: Date? {
            if case let .pause(deadline, _) = self { return deadline }
            return nil
        }
    }

    /// A new pause always replaces a running one, even with a shorter duration.
    public static func resolve(
        durationMinutes: Int,
        now: Date,
        protectionActive: Bool,
        currentPausedUntil: Date?
    ) -> Result {
        guard protectionActive else { return .noop }
        let deadline = now.addingTimeInterval(TimeInterval(durationMinutes) * 60)
        let replaced = currentPausedUntil.map { $0 > now } ?? false
        return .pause(deadline: deadline, replacedExisting: replaced)
    }
}
