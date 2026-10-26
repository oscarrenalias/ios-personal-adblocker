import Foundation

/// What the Settings ▸ DNS cache row shows. Pure logic: callers pass the
/// tunnel's connection state and the latest runtime stats.
public struct CacheRowPresentation: Equatable, Sendable {
    public let text: String

    public init(tunnelConnected: Bool, stats: TunnelRuntimeStats?) {
        guard tunnelConnected, let entries = stats?.cacheEntries else {
            text = "Not available"
            return
        }
        text = entries == 1 ? "1 entry" : "\(entries) entries"
    }
}
