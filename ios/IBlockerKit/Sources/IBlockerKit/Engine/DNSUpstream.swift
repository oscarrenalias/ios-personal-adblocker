import Foundation

/// A resolver the engine forwards non-blocked queries to.
/// Takes and returns raw DNS messages so EDNS options pass through untouched.
public protocol DNSUpstream: Sendable {
    func resolve(_ query: Data) async throws -> Data
    /// Resolves and reports which route served the query. Non-routing upstreams report `.network`.
    func resolveWithRoute(_ query: Data) async throws -> (Data, UpstreamRoute)
    /// Drops the current connection so the next query uses a new one. Used when a
    /// query stalls; upstreams without a persistent connection do nothing.
    func resetConnection(reason: String)
}

extension DNSUpstream {
    public func resolveWithRoute(_ query: Data) async throws -> (Data, UpstreamRoute) {
        (try await resolve(query), .network)
    }

    public func resetConnection(reason: String) {}
}

/// Which path served (or failed) a query.
public enum UpstreamRoute: Equatable, Sendable {
    case alternative
    case network
    case networkOnlyName
    case fallback
    case local
}

/// A resolve failure tagged with the route that was in use.
public struct RoutedError: Error, Sendable {
    public let route: UpstreamRoute
    public let underlying: Error

    public init(route: UpstreamRoute, underlying: Error) {
        self.route = route
        self.underlying = underlying
    }
}

public enum UpstreamError: Error, Equatable {
    case timeout
    case badResponse
    case connectionFailed(String)
}
