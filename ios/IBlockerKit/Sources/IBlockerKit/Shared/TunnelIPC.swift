import Foundation

/// Upstream resolver configuration, stored in shared defaults and passed to
/// the tunnel over IPC.
public struct UpstreamConfig: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case doh
        case udp
        case network
    }

    public var kind: Kind
    /// DoH endpoint. Presets use IP-literal URLs (https://94.140.14.14/dns-query)
    /// because the extension's own hostname lookups would recurse through the
    /// tunnel it is serving.
    public var dohURL: String?
    /// Plain-DNS server IP for UDP upstreams.
    public var udpAddress: String?

    public init(kind: Kind, dohURL: String? = nil, udpAddress: String? = nil) {
        self.kind = kind
        self.dohURL = dohURL
        self.udpAddress = udpAddress
    }

    /// Network DNS: resolves via the current network's own DNS on the physical
    /// interface (no fixed third-party resolver).
    public static let `default` = UpstreamConfig(kind: .network)

    /// True only for DoH; UDP and network DNS are unencrypted.
    public var isEncrypted: Bool { kind == .doh }

    public var displayName: String {
        switch kind {
        case .doh: return dohURL ?? "DoH"
        case .udp: return "\(udpAddress ?? "?"):53 (UDP)"
        case .network: return "Network DNS"
        }
    }
}

/// Requests the app sends to the tunnel via sendProviderMessage.
public enum TunnelRequest: Codable, Sendable {
    case ping
    case reloadRules
    case getStats
    case setResolverSettings(ResolverSettings)
    /// Suspend blocking until the given instant; nil resumes.
    case setPause(until: Date?)
    /// Drop every cached DNS answer; answered with .ok.
    case clearDNSCache
}

public struct TunnelRuntimeStats: Codable, Sendable, Equatable {
    public var startedAt: Date?
    public var totalQueries: UInt64
    public var blockedQueries: UInt64
    public var blocklistEntryCount: UInt64
    public var memoryBytes: UInt64?
    /// Non-nil when blocking is currently paused; the instant it resumes.
    public var pausedUntil: Date?
    /// Resolver health as seen by the router; nil when reported by an older tunnel.
    public var resolverStatus: ResolverStatus?
    /// DNS cache counters; nil when reported by an older tunnel.
    public var cacheEntries: UInt64?
    public var cacheHits: UInt64?
    public var cacheMisses: UInt64?

    public init(startedAt: Date? = nil, totalQueries: UInt64 = 0, blockedQueries: UInt64 = 0,
                blocklistEntryCount: UInt64 = 0, memoryBytes: UInt64? = nil, pausedUntil: Date? = nil,
                resolverStatus: ResolverStatus? = nil, cacheEntries: UInt64? = nil,
                cacheHits: UInt64? = nil, cacheMisses: UInt64? = nil) {
        self.startedAt = startedAt
        self.totalQueries = totalQueries
        self.blockedQueries = blockedQueries
        self.blocklistEntryCount = blocklistEntryCount
        self.memoryBytes = memoryBytes
        self.pausedUntil = pausedUntil
        self.resolverStatus = resolverStatus
        self.cacheEntries = cacheEntries
        self.cacheHits = cacheHits
        self.cacheMisses = cacheMisses
    }

    private enum CodingKeys: String, CodingKey {
        case startedAt, totalQueries, blockedQueries, blocklistEntryCount, memoryBytes
        case pausedUntil, resolverStatus, cacheEntries, cacheHits, cacheMisses
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        totalQueries = try c.decode(UInt64.self, forKey: .totalQueries)
        blockedQueries = try c.decode(UInt64.self, forKey: .blockedQueries)
        blocklistEntryCount = try c.decode(UInt64.self, forKey: .blocklistEntryCount)
        memoryBytes = try c.decodeIfPresent(UInt64.self, forKey: .memoryBytes)
        pausedUntil = try c.decodeIfPresent(Date.self, forKey: .pausedUntil)
        resolverStatus = try c.decodeIfPresent(ResolverStatus.self, forKey: .resolverStatus)
        cacheEntries = try c.decodeIfPresent(UInt64.self, forKey: .cacheEntries)
        cacheHits = try c.decodeIfPresent(UInt64.self, forKey: .cacheHits)
        cacheMisses = try c.decodeIfPresent(UInt64.self, forKey: .cacheMisses)
    }
}

public enum TunnelResponse: Codable, Sendable {
    case ok
    case stats(TunnelRuntimeStats)
    case failure(String)
}

public enum TunnelIPCCoder {
    public static func encode(_ request: TunnelRequest) throws -> Data {
        try JSONEncoder().encode(request)
    }
    public static func decodeRequest(_ data: Data) throws -> TunnelRequest {
        try JSONDecoder().decode(TunnelRequest.self, from: data)
    }
    public static func encode(_ response: TunnelResponse) throws -> Data {
        try JSONEncoder().encode(response)
    }
    public static func decodeResponse(_ data: Data) throws -> TunnelResponse {
        try JSONDecoder().decode(TunnelResponse.self, from: data)
    }
}
