import Foundation

public enum ResolverRouterError: Error, Equatable, Sendable {
    case timeout
    case alternativeFailed(String)
}

/// Routes each query to the network's DNS or the user-selected alternative.
///
/// Rules, in order: `local` / `*.local` get NXDOMAIN with no upstream; with the
/// alternative off everything goes to `network`; network-only names go to
/// `network` without probing. Alternative-on routing (health, failover,
/// probes) is layered on top of this. With the alternative healthy, queries go
/// to it with a 2 s timeout; failures follow the fallback policy.
public final class ResolverRouter: DNSUpstream, @unchecked Sendable {
    private static let log = Log(category: "router")

    public typealias Alternative = (upstream: DNSUpstream, name: String, encrypted: Bool)

    /// Router-enforced limit on a single alternative query.
    public static let alternativeTimeout: TimeInterval = 2

    private let network: DNSUpstream
    private let alternative: Alternative?
    private let policy: FallbackPolicy
    private let lock = NSLock()
    private var breaker: CircuitBreaker

    public init(
        network: DNSUpstream,
        alternative: Alternative?,
        policy: FallbackPolicy,
        breaker: CircuitBreaker? = nil
    ) {
        self.network = network
        self.alternative = alternative
        self.policy = policy
        self.breaker = breaker ?? CircuitBreaker(
            name: alternative?.name ?? "none",
            effect: policy == .networkDNS ? "using network DNS" : "queries fail"
        )
    }

    public func resolve(_ query: Data) async throws -> Data {
        let parsed = try? DNSParser.parseQuery(query)

        if let parsed, Self.isLocal(parsed.questionName) {
            Self.logRoute(parsed, rule: "local-nxdomain")
            return DNSResponseBuilder.nxdomain(for: parsed)
        }
        if alternative == nil {
            Self.logRoute(parsed, rule: "alternative-off")
            return try await network.resolve(query)
        }
        if let parsed, NetworkOnlyNames.matches(parsed.questionName) {
            Self.logRoute(parsed, rule: "network-only")
            return try await network.resolve(query)
        }
        guard let alternative else { return try await network.resolve(query) }
        return try await resolveViaAlternative(query, parsed: parsed, alternative: alternative)
    }

    /// Tries the alternative when its breaker is healthy; otherwise (or on failure)
    /// applies the fallback policy. Unparseable queries follow the same path.
    private func resolveViaAlternative(_ query: Data, parsed: DNSQuery?, alternative: Alternative) async throws -> Data {
        let attempt: (healthy: Bool, generation: Int) = lock.withLock { (!breaker.isDown, breaker.generation) }
        guard attempt.healthy else {
            Self.logRoute(parsed, rule: "failing")
            return try await fallBack(query, parsed: parsed, error: "alternative resolver marked down", elapsed: 0)
        }

        Self.logRoute(parsed, rule: "alternative")
        let start = Date()
        do {
            let response = try await Self.withTimeout(Self.alternativeTimeout) {
                try await alternative.upstream.resolve(query)
            }
            lock.withLock { breaker.recordSuccess(generation: attempt.generation) }
            return response
        } catch {
            lock.withLock { breaker.recordFailure(generation: attempt.generation) }
            return try await fallBack(
                query, parsed: parsed, error: "\(error)", elapsed: Date().timeIntervalSince(start)
            )
        }
    }

    private func fallBack(_ query: Data, parsed: DNSQuery?, error: String, elapsed: TimeInterval) async throws -> Data {
        switch policy {
        case .networkDNS:
            Self.logRoute(parsed, rule: "fallback")
            Self.log.debug("\(Self.target(parsed)) alternative failed, re-sending to network: \(error) after \(Int((elapsed * 1000).rounded())) ms")
            return try await network.resolve(query)
        case .none:
            Self.log.debug("\(Self.target(parsed)) alternative failed, no fallback: \(error)")
            throw ResolverRouterError.alternativeFailed(error)
        }
    }

    private static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ResolverRouterError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw ResolverRouterError.timeout }
            return first
        }
    }

    private static func target(_ query: DNSQuery?) -> String {
        guard let query else { return "unparseable" }
        return "domain=\(query.questionName) qtype=\(DNSRecordType.name(query.qtype))"
    }

    private static func isLocal(_ name: String) -> Bool {
        name == "local" || name.hasSuffix(".local")
    }

    private static func logRoute(_ query: DNSQuery?, rule: String) {
        log.debug(describe(query, rule: rule))
    }

    private static func describe(_ query: DNSQuery?, rule: String) -> String {
        guard let query else { return "route rule=\(rule) unparseable" }
        return "route domain=\(query.questionName) qtype=\(DNSRecordType.name(query.qtype)) rule=\(rule)"
    }
}
