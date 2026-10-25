import Foundation

/// Formats how long ago a filter list was last updated, e.g. "updated 3 h ago".
public enum ListAgeText {
    /// Rounds down; negative intervals (clock skew) clamp to "just now".
    public static func updated(since: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        switch seconds {
        case ..<60:
            return "updated just now"
        case ..<3600:
            return "updated \(seconds / 60) min ago"
        case ..<86400:
            return "updated \(seconds / 3600) h ago"
        default:
            let days = seconds / 86400
            return days == 1 ? "updated 1 day ago" : "updated \(days) days ago"
        }
    }
}
