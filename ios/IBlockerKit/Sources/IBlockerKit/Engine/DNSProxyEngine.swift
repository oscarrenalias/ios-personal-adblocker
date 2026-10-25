import Foundation

/// The tunnel's brain: raw IP packet in → verdict → raw IP packet out (or
/// nil to drop). Pure logic over injected collaborators, so the whole path
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

        public init(blockTTL: UInt32 = 300, maxInFlight: Int = 256, mtu: Int = TunnelConstants.mtu,
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
    private let startedAt = Date()
    private var inFlight = 0
    /// While set to a future instant, blocking is suspended and every query
    /// is forwarded (a temporary "let everything through").
    private var pausedUntil: Date?

    public init(matcher: DomainMatcher,
                upstream: DNSUpstream,
                logWriter: QueryLogRingWriter?,
                statsURL: URL?,
                configuration: Configuration = Configuration()) {
        self.matcher = matcher
        self.upstream = upstream
        self.logWriter = logWriter
        self.statsURL = statsURL
        self.configuration = configuration
        self.stats = statsURL.map { StatsPersistence.load(from: $0) } ?? BlockerStats()
    }

    // MARK: - Packet path

    public func handlePacket(_ packet: Data) async -> Data? {
        guard let udp = PacketParser.parseUDP(packet), udp.destinationPort == 53 else {
            return nil
        }
        let message = Data(udp.payload)

        let query: DNSQuery
        do {
            query = try DNSParser.parseQuery(message)
        } catch {
            // Responses, multi-question or exotic messages: forward untouched.
            return await forward(raw: message, query: nil, udp: udp)
        }

        if !isPaused, query.qclass == 1, matcher.verdict(for: query.questionName) == .block {
            Self.log.debug("query \(query.questionName) qtype \(query.qtype): blocked")
            record(name: query.questionName, qtype: query.qtype, verdict: .blocked)
            let response = DNSResponseBuilder.blocked(for: query, ttl: configuration.blockTTL)
            return UDPReplyBuilder.reply(to: udp, payload: [UInt8](response))
        }

        return await forward(raw: query.raw, query: query, udp: udp)
    }

    private func forward(raw: Data, query: DNSQuery?, udp: ParsedUDPPacket) async -> Data? {
        guard inFlight < configuration.maxInFlight else {
            if let query {
                Self.log.debug("query \(query.questionName) qtype \(query.qtype): failed (in-flight limit \(configuration.maxInFlight) reached)")
                record(name: query.questionName, qtype: query.qtype, verdict: .failed)
                let servfail = DNSResponseBuilder.servfail(for: query)
                return UDPReplyBuilder.reply(to: udp, payload: [UInt8](servfail))
            }
            Self.log.debug("unparseable query dropped (in-flight limit \(configuration.maxInFlight) reached)")
            return nil
        }

        inFlight += 1
        defer { inFlight -= 1 }

        let started = Date()
        do {
            let answer = try await upstream.resolve(raw)
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            if let query {
                Self.log.debug("query \(query.questionName) qtype \(query.qtype): allowed in \(elapsedMs) ms")
                record(name: query.questionName, qtype: query.qtype, verdict: .allowed)
            }
            let ipOverhead = udp.ipVersion == 4 ? 28 : 48
            if answer.count + ipOverhead > configuration.mtu {
                if let query {
                    Self.log.debug("query \(query.questionName): answer \(answer.count) bytes exceeds MTU, truncated")
                    let truncated = DNSResponseBuilder.truncated(for: query)
                    return UDPReplyBuilder.reply(to: udp, payload: [UInt8](truncated))
                }
                Self.log.debug("answer \(answer.count) bytes exceeds MTU, dropped")
                return nil
            }
            return UDPReplyBuilder.reply(to: udp, payload: [UInt8](answer))
        } catch {
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            if let query {
                Self.log.debug("query \(query.questionName) qtype \(query.qtype): failed in \(elapsedMs) ms, returning SERVFAIL: \(error)")
                record(name: query.questionName, qtype: query.qtype, verdict: .failed)
                let servfail = DNSResponseBuilder.servfail(for: query)
                return UDPReplyBuilder.reply(to: udp, payload: [UInt8](servfail))
            }
            Self.log.debug("unparseable query dropped after upstream error in \(elapsedMs) ms: \(error)")
            return nil
        }
    }

    private func record(name: String, qtype: UInt16, verdict: LogVerdict) {
        let now = Date()
        stats.record(blocked: verdict == .blocked, on: BlockerStats.dayKey(for: now))
        if configuration.logEnabled, let writer = logWriter {
            writer.append(QueryLogRecord(
                timestampMillis: UInt64(now.timeIntervalSince1970 * 1000),
                qtype: qtype,
                verdict: verdict,
                domain: name
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
            pausedUntil: isPaused ? pausedUntil : nil
        )
    }

    /// Persists pending log records and counters. Called on a slow timer by
    /// the provider, before stats snapshots, and at tunnel shutdown.
    public func flush() {
        try? logWriter?.flush()
        if let statsURL {
            StatsPersistence.save(stats, to: statsURL)
        }
    }
}
