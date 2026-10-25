import Foundation

/// Routes each query to the network's DNS or the user-selected alternative.
///
/// Rules, in order: `local` / `*.local` get NXDOMAIN with no upstream; with the
/// alternative off everything goes to `network`; network-only names go to
/// `network` without probing. Alternative-on routing (health, failover,
/// probes) is layered on top of this.
public final class ResolverRouter: DNSUpstream, @unchecked Sendable {
    private static let log = Log(category: "router")

    public typealias Alternative = (upstream: DNSUpstream, name: String, encrypted: Bool)

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
        // Alternative-on routing beyond network-only names is added separately;
        // until then these queries use the network.
        Self.logRoute(parsed, rule: "network-default")
        return try await network.resolve(query)
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
