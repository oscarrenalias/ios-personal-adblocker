import Foundation

/// What the Settings ▸ DNS cache row shows. Pure logic: callers pass the
/// tunnel's connection state and the latest runtime stats.
public struct CacheRowPresentation: Equatable, Sendable {
    public let text: String

    public init(tunnelConnected: Bool, stats: TunnelRuntimeStats?) {
        guard tunnelConnected, let stats,
              let entries = stats.cacheEntries,
              let hits = stats.cacheHits,
              let misses = stats.cacheMisses else {
            text = "Not available"
            return
        }
        let (lookups, overflow) = hits.addingReportingOverflow(misses)
        if !overflow, lookups == 0 {
            text = "\(entries) entries · no lookups yet"
            return
        }
        // Rounded down. Integer maths avoids float rounding at exact percents;
        // on overflow fall back to a floating-point ratio.
        let percent: UInt64
        if overflow {
            percent = UInt64((Double(hits) / (Double(hits) + Double(misses)) * 100).rounded(.down))
        } else {
            percent = hits <= UInt64.max / 100 ? hits * 100 / lookups : UInt64(Double(hits) / Double(lookups) * 100)
        }
        text = "\(entries) entries · \(percent)% hit rate"
    }
}
