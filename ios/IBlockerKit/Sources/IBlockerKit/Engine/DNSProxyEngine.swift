import Foundation

/// The tunnel's brain: raw IP packet in → verdict → raw IP packet(s) out (or
/// none to drop; large answers come back as IP fragments). Pure logic over injected collaborators, so the whole path
/// is unit-testable off-device.
///
/// Concurrency: an actor, but reentrant — `handlePacket` suspends while an
/// upstream lookup is in flight, letting other packets proceed. State
/// mutation (stats, log, counters) happens only between suspension points.
public actor DNSProxyEngine {

    public struct Configuration: Sendable {
        public var blockTTL: UInt32
        public var maxInFlight: Int
        public var mtu: Int
        public var logEnabled: Bool

        public init(blockTTL: UInt32 = 10, maxInFlight: Int = 256, mtu: Int = TunnelConstants.mtu,
                    logEnabled: Bool = true) {
            self.blockTTL = blockTTL
            self.maxInFlight = maxInFlight
            self.mtu = mtu
            self.logEnabled = logEnabled
        }
    }

    private static let log = Log(category: "engine")

    private var matcher: DomainMatcher
    private var upstream: DNSUpstream
    private let logWriter: QueryLogRingWriter?
    private let statsURL: URL?
    private var configuration: Configuration
    private var stats: BlockerStats
    /// Last stats value persisted (or loaded); flush skips the write when unchanged.
    private var lastWrittenStats: BlockerStats
    private let startedAt = Date()
    private var inFlight = 0
    private var cache: DNSCache
    /// While set to a future instant, blocking is suspended and every query
    /// is forwarded (a temporary "let everything through").
    private var pausedUntil: Date?

    public init(matcher: DomainMatcher,
                upstream: DNSUpstream,
                logWriter: QueryLogRingWriter?,
                statsURL: URL?,
                configuration: Configuration = Configuration(),
                cache: DNSCache = DNSCache()) {
        self.cache = cache
        self.matcher = matcher
        self.upstream = upstream
        self.logWriter = logWriter
        self.statsURL = statsURL
        self.configuration = configuration
        let loaded = statsURL.map { StatsPersistence.load(from: $0) } ?? BlockerStats()
        self.stats = loaded
        self.lastWrittenStats = loaded
    }

    // MARK: - Decision attribution

    /// Why a query got its verdict, as recorded in the log details.
    private struct Decision {
        var source: UInt8
        var sourceNumber: UInt8 = 0
        var matchedLabels: UInt8 = 0
        /// Debug-log form: `source=<kind>[#n] suffix=<matched>`.
        var description: String

        static let none = Decision(source: 1, description: "source=none")
        static let paused = Decision(source: 7, description: "source=paused")

        init(source: UInt8, sourceNumber: UInt8 = 0, matchedLabels: UInt8 = 0, description: String) {
            self.source = source
            self.sourceNumber = sourceNumber
            self.matchedLabels = matchedLabels
            self.description = description
        }

        init(_ match: DomainMatcher.Match) {
            let kind: String
            var code: UInt8
            var number: UInt8 = 0
            switch match.source {
            case .userAllowlist: kind = "userAllow"; code = 2
            case .userDenylist: kind = "userDeny"; code = 3
            case .builtIn: kind = "builtIn"; code = 4
            case .listException(let n): kind = "listException#\(n)"; code = 5; number = n
            case .list(let n): kind = "list#\(n)"; code = 6; number = n
            }
            let labels = match.matchedSuffix.split(separator: ".").count
            self.init(source: code, sourceNumber: number, matchedLabels: UInt8(clamping: labels),
                      description: "source=\(kind) suffix=\(match.matchedSuffix)")
        }
    }

    private static func logRoute(_ route: UpstreamRoute) -> LogRoute {
        switch route {
        case .alternative: return .alternative
        case .network: return .network
        case .networkOnlyName: return .networkOnlyName
        case .fallback: return .fallback
        case .local: return .local
        }
    }

    // MARK: - Packet path

    public func handlePacket(_ packet: Data) async -> [Data] {
        guard let udp = PacketParser.parseUDP(packet), udp.destinationPort == 53 else {
            return []
        }
        let message = Data(udp.payload)

        let query: DNSQuery
        do {
            query = try DNSParser.parseQuery(message)
        } catch {
            // Responses, multi-question or exotic messages: forward untouched.
            return await forward(raw: message, query: nil, udp: udp, decision: .none)
        }

        var decision = Decision.none
        if isPaused {
            decision = .paused
        } else if query.qclass == 1 {
            let explanation = matcher.explain(query.questionName)
            if let match = explanation.decidingMatch {
                decision = Decision(match)
            }
            if explanation.verdict == .block {
                Self.log.debug("query \(query.questionName) qtype \(query.qtype): blocked \(decision.description)")
                record(name: query.questionName, qtype: query.qtype, verdict: .blocked,
                       decision: decision, cacheHit: false, route: .alternative)
                let response = DNSResponseBuilder.blocked(for: query, ttl: configuration.blockTTL)
                return packets(for: udp, payload: [UInt8](response))
            }
        }

        cache.maintain()
        if case .hit(let cached) = cache.lookup(query: query),
           cached.count <= UDPReplyBuilder.maxPayload(ipVersion: udp.ipVersion) {
            // Served outside `forward`, so hits never count toward inFlight.
            Self.log.debug("query \(query.questionName) qtype \(query.qtype): allowed \(decision.description) route=0 cache=true")
            record(name: query.questionName, qtype: query.qtype, verdict: .allowed,
                   decision: decision, cacheHit: true, route: .alternative)
            let result = packets(for: udp, payload: [UInt8](cached))
            if result.count > 1 {
                Self.log.debug("query \(query.questionName): fragmented cached reply, answer \(cached.count) bytes, \(result.count) fragments")
            }
            return result
        }

        return await forward(raw: query.raw, query: query, udp: udp, decision: decision)
    }

    private func forward(raw: Data, query: DNSQuery?, udp: ParsedUDPPacket, decision: Decision) async -> [Data] {
        guard inFlight < configuration.maxInFlight else {
            if let query {
                Self.log.debug("query \(query.questionName) qtype \(query.qtype): failed \(decision.description) route=0 cache=false (in-flight limit \(configuration.maxInFlight) reached)")
                record(name: query.questionName, qtype: query.qtype, verdict: .failed,
                       decision: decision, cacheHit: false, route: .alternative)
                let servfail = DNSResponseBuilder.servfail(for: query)
                return packets(for: udp, payload: [UInt8](servfail))
            }
            Self.log.debug("unparseable query dropped (in-flight limit \(configuration.maxInFlight) reached)")
            return []
        }

        inFlight += 1
        defer { inFlight -= 1 }

        let started = Date()
        let cacheGeneration = cache.generation
        do {
            let (answer, upstreamRoute) = try await upstream.resolveWithRoute(raw)
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            if let query {
                Self.log.debug("query \(query.questionName) qtype \(query.qtype): allowed \(decision.description) route=\(upstreamRoute) cache=false in \(elapsedMs) ms")
                record(name: query.questionName, qtype: query.qtype, verdict: .allowed,
                       decision: decision, cacheHit: false, route: Self.logRoute(upstreamRoute))
                if cache.generation == cacheGeneration {
                    cache.store(query: query, response: answer)
                } else if DNSCache.bypassReason(for: query) == nil {
                    Self.log.debug("not cached \(query.questionName) \(DNSRecordType.name(query.qtype)): cache cleared while in flight")
                }
            }
            if answer.count > UDPReplyBuilder.maxPayload(ipVersion: udp.ipVersion) {
                if let query {
                    Self.log.debug("query \(query.questionName): answer \(answer.count) bytes exceeds max UDP datagram, truncated (TC)")
                    let truncated = DNSResponseBuilder.truncated(for: query)
                    return packets(for: udp, payload: [UInt8](truncated))
                }
                Self.log.debug("answer \(answer.count) bytes exceeds max UDP datagram, dropped")
                return []
            }
            let result = packets(for: udp, payload: [UInt8](answer))
            if result.count > 1 {
                Self.log.debug("query \(query?.questionName ?? "?"): fragmented reply, answer \(answer.count) bytes, \(result.count) fragments")
            }
            return result
        } catch {
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            if let query {
                let failedRoute = (error as? RoutedError)?.route
                Self.log.debug("query \(query.questionName) qtype \(query.qtype): failed \(decision.description) route=\(failedRoute.map { "\($0)" } ?? "0") cache=false in \(elapsedMs) ms, returning SERVFAIL: \(error)")
                record(name: query.questionName, qtype: query.qtype, verdict: .failed,
                       decision: decision, cacheHit: false,
                       route: failedRoute.map(Self.logRoute) ?? .alternative)
                let servfail = DNSResponseBuilder.servfail(for: query)
                return packets(for: udp, payload: [UInt8](servfail))
            }
            Self.log.debug("unparseable query dropped after upstream error in \(elapsedMs) ms: \(error)")
            return []
        }
    }

    private func packets(for udp: ParsedUDPPacket, payload: [UInt8]) -> [Data] {
        UDPReplyBuilder.replyPackets(to: udp, payload: payload, mtu: configuration.mtu)
    }

    private func record(name: String, qtype: UInt16, verdict: LogVerdict,
                        decision: Decision, cacheHit: Bool, route: LogRoute) {
        let now = Date()
        stats.record(blocked: verdict == .blocked, on: BlockerStats.dayKey(for: now))
        if configuration.logEnabled, let writer = logWriter {
            writer.append(QueryLogRecord(
                timestampMillis: UInt64(now.timeIntervalSince1970 * 1000),
                qtype: qtype,
                verdict: verdict,
                listId: decision.source,
                domain: name,
                details: QueryLogDetails(cacheHit: cacheHit, route: route,
                                         sourceNumber: decision.sourceNumber,
                                         matchedLabels: decision.matchedLabels)
            ))
        }
    }

    // MARK: - Control

    public func reload(matcher: DomainMatcher) {
        self.matcher = matcher
        Self.log.info("rules reloaded: \(matcher.blockedEntryCount) blocked entries, generation \(matcher.blocklist?.generation.description ?? "none")")
    }

    public func setUpstream(_ upstream: DNSUpstream) {
        self.upstream = upstream
        Self.log.info("upstream switched")
        clearCache(reason: .resolverChange)
    }

    /// Drops every cached answer; in-flight lookups started before this call won't be stored.
    @discardableResult
    public func clearCache(reason: DNSCache.ClearReason) -> Int {
        cache.clear(reason: reason)
    }

    /// Suspends blocking until `date` (nil resumes immediately).
    public func setPaused(until date: Date?) {
        pausedUntil = date
    }

    private var isPaused: Bool {
        guard let pausedUntil else { return false }
        return pausedUntil > Date()
    }

    public func setLogEnabled(_ enabled: Bool) {
        configuration.logEnabled = enabled
    }

    public var blockedEntryCount: Int {
        matcher.blockedEntryCount
    }

    public var blocklistGeneration: UInt32? {
        matcher.blocklist?.generation
    }

    public func statsSnapshot(memoryBytes: UInt64? = nil) -> TunnelRuntimeStats {
        TunnelRuntimeStats(
            startedAt: startedAt,
            totalQueries: stats.totalQueries,
            blockedQueries: stats.totalBlocked,
            blocklistEntryCount: UInt64(matcher.blockedEntryCount),
            memoryBytes: memoryBytes,
            pausedUntil: isPaused ? pausedUntil : nil,
            cacheEntries: UInt64(cache.entryCount),
            cacheHits: cache.counters.hits,
            cacheMisses: cache.counters.misses
        )
    }

    /// Persists pending log records and counters. Called on a slow timer by
    /// the provider, before stats snapshots, and at tunnel shutdown.
    public func flush() {
        try? logWriter?.flush()
        if let statsURL, stats != lastWrittenStats {
            StatsPersistence.save(stats, to: statsURL)
            lastWrittenStats = stats
        }
    }
}
