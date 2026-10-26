import Foundation

/// Bounded in-memory store for DNS responses (see specs/planned/dns-caching-in-the-tunnel.md).
///
/// Pure storage: it keeps response bytes and the TTL decided by the caller,
/// and enforces the entry and byte limits with LRU eviction. Parsing,
/// TTL computation and rewriting a hit for a new query live elsewhere. Not
/// thread-safe; the owner (the engine actor) serializes access. The clock is
/// injected so expiry, purge and log throttling are testable.
public struct DNSCache: Sendable {
    /// Lookup key: the query's wire-form question (name, qtype, qclass),
    /// ASCII-lowercased, plus whether the query carried EDNS.
    public struct Key: Hashable, Sendable {
        public let question: [UInt8]
        public let hasEDNS: Bool

        public init(rawQuestion: [UInt8], hasEDNS: Bool) {
            // Fold only the name's label bytes. The length bytes, qtype and
            // qclass stay untouched (qtype 65 is 0x0041, which must not
            // collide with 0x0061).
            var out = rawQuestion
            var i = 0
            while i < out.count, out[i] != 0 {
                let end = min(i + 1 + Int(out[i]), out.count)
                var j = i + 1
                while j < end {
                    if out[j] >= 0x41 && out[j] <= 0x5A { out[j] |= 0x20 }
                    j += 1
                }
                i = end
            }
            question = out
            self.hasEDNS = hasEDNS
        }
    }

    public struct Entry: Equatable, Sendable {
        public let response: [UInt8]
        /// Seconds the entry may be served for, counted from `storedAt`.
        public let entryTTL: UInt32
        public let storedAt: Date

        /// Whole seconds since the entry was stored.
        public func age(at now: Date) -> UInt32 {
            let seconds = now.timeIntervalSince(storedAt)
            guard seconds > 0 else { return 0 }
            return UInt32(min(seconds, Double(UInt32.max)))
        }

        public func isExpired(at now: Date) -> Bool {
            Int64(entryTTL) - Int64(age(at: now)) <= 0
        }
    }

    public enum ClearReason: String, Sendable {
        case resolverChange = "resolver change"
        case resolverStatusChange = "resolver status change"
        case networkChange = "network change"
        case user = "user"
        case tunnelStop = "tunnel stop"
    }

    public struct Counters: Equatable, Sendable {
        public var hits: UInt64 = 0
        public var misses: UInt64 = 0
        public var evictions: UInt64 = 0
    }

    public static let maxEntries = 2_000
    public static let maxBytes = 1_048_576
    public static let purgeInterval: TimeInterval = 60
    public static let evictionLogInterval: TimeInterval = 60
    public static let summaryInterval: TimeInterval = 600

    private static let log = Log(category: "cache")

    private struct Slot: Sendable {
        var entry: Entry
        var lastUsed: UInt64
    }

    private var slots: [Key: Slot] = [:]
    private var useTick: UInt64 = 0
    private(set) var totalBytes = 0

    /// Bumped by every `clear()`. Callers capture it before an upstream call
    /// and store the answer only if it is unchanged.
    public private(set) var generation: UInt64 = 0
    public private(set) var counters = Counters()

    private let maxEntries: Int
    private let maxBytes: Int
    private let now: @Sendable () -> Date

    private var lastPurge: Date
    private var lastEvictionLog: Date
    private var lastSummary: Date
    private var pendingEvictionsByCount = 0
    private var pendingEvictionsByBytes = 0
    private var summaryBaseline = Counters()

    public init(
        maxEntries: Int = DNSCache.maxEntries,
        maxBytes: Int = DNSCache.maxBytes,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.maxEntries = maxEntries
        self.maxBytes = maxBytes
        self.now = now
        let start = now()
        lastPurge = start
        lastEvictionLog = start
        lastSummary = start
    }

    public var entryCount: Int { slots.count }
    public var byteCount: Int { totalBytes }

    /// Returns the unexpired entry for `key` and marks it most recently used,
    /// counting a hit. An expired entry is removed. No entry counts a miss.
    public mutating func lookup(_ key: Key) -> Entry? {
        let current = now()
        guard var slot = slots[key] else {
            counters.misses += 1
            return nil
        }
        if slot.entry.isExpired(at: current) {
            remove(key)
            counters.misses += 1
            return nil
        }
        useTick += 1
        slot.lastUsed = useTick
        slots[key] = slot
        counters.hits += 1
        return slot.entry
    }

    /// Stores `response` for `key`, replacing any existing entry, then evicts
    /// least recently used entries until both limits hold. Returns false when
    /// nothing was stored (TTL 0, or the response alone exceeds the byte limit).
    @discardableResult
    public mutating func store(_ key: Key, response: [UInt8], entryTTL: UInt32) -> Bool {
        guard entryTTL > 0, response.count <= maxBytes else { return false }
        let current = now()
        if slots[key] != nil { remove(key) }
        useTick += 1
        slots[key] = Slot(
            entry: Entry(response: response, entryTTL: entryTTL, storedAt: current),
            lastUsed: useTick)
        totalBytes += response.count

        while slots.count > maxEntries { evictLeastRecentlyUsed(byBytes: false) }
        while totalBytes > maxBytes { evictLeastRecentlyUsed(byBytes: true) }

        maintain()
        return true
    }

    /// Applies the store rules to an upstream `response` for `query` and, when
    /// it is cacheable, stores it under the query's key. Returns false (and
    /// debug-logs the reason) when the response is not cached.
    @discardableResult
    public mutating func store(query: DNSQuery, response: Data) -> Bool {
        let label = "\(query.questionName) \(DNSRecordType.name(query.qtype))"
        if let reason = Self.bypassReason(for: query) {
            Self.log.debug("not cached \(label): \(reason)")
            return false
        }
        let bytes = [UInt8](response)
        switch Self.entryTTL(query: query, response: bytes) {
        case .failure(let reason):
            Self.log.debug("not cached \(label): \(reason.description)")
            return false
        case .success(let ttl):
            let key = Key(rawQuestion: query.rawQuestion, hasEDNS: query.hasAdditionalRecords)
            guard store(key, response: bytes, entryTTL: ttl) else {
                Self.log.debug("not cached \(label): TTL 0 or too large")
                return false
            }
            Self.log.debug("stored \(label), ttl \(ttl) s")
            return true
        }
    }

    /// Why a query must skip the cache (no lookup, no store), or nil when it
    /// may use it. Only IN queries qualify; CD and the OPT DO bit bypass.
    static func bypassReason(for query: DNSQuery) -> String? {
        guard query.qclass == 1 else { return "class not IN" }
        if query.flags & 0x0010 != 0 { return "CD set" }
        if query.hasAdditionalRecords {
            guard let records = try? DNSRecordWalker.walk([UInt8](query.raw)) else {
                return "unparseable query"
            }
            // The OPT TTL field holds ext-rcode, version and flags; DO is the top flag bit.
            if records.contains(where: { $0.isOPT && $0.ttl & 0x8000 != 0 }) { return "DO set" }
        }
        return nil
    }

    enum NotCacheable: Error, Equatable {
        case unparseable
        case tooLarge
        case notAResponse
        case truncated
        case questionMismatch
        case rcode(UInt8)
        case zeroTTL

        var description: String {
            switch self {
            case .unparseable: return "unparseable response"
            case .tooLarge: return "response over \(DNSCache.maxResponseBytes) bytes"
            case .notAResponse: return "not a response"
            case .truncated: return "TC set"
            case .questionMismatch: return "question mismatch"
            case .rcode(let code): return code == 2 ? "SERVFAIL" : code == 5 ? "REFUSED" : "rcode \(code)"
            case .zeroTTL: return "TTL 0"
            }
        }
    }

    public static let maxResponseBytes = 4_096
    static let maxPositiveTTL: UInt32 = 3_600
    static let maxNegativeTTL: UInt32 = 300
    static let noSOANegativeTTL: UInt32 = 30

    /// Computes the cache TTL for `response`, or why it can't be cached.
    static func entryTTL(query: DNSQuery, response: [UInt8]) -> Result<UInt32, NotCacheable> {
        guard response.count <= maxResponseBytes else { return .failure(.tooLarge) }
        guard response.count >= 12 else { return .failure(.unparseable) }
        let flags = (UInt16(response[2]) << 8) | UInt16(response[3])
        guard flags & 0x8000 != 0 else { return .failure(.notAResponse) }
        guard flags & 0x0200 == 0 else { return .failure(.truncated) }
        let rcode = UInt8(flags & 0x000F)
        guard rcode == 0 || rcode == 3 else { return .failure(.rcode(rcode)) }

        let qd = (Int(response[4]) << 8) | Int(response[5])
        guard qd == 1 else { return .failure(.questionMismatch) }
        guard let nameEnd = try? DNSRecordWalker.skipName(response, at: 12),
              nameEnd + 4 <= response.count else { return .failure(.unparseable) }
        let echoed = Key(rawQuestion: Array(response[12..<(nameEnd + 4)]), hasEDNS: false)
        let asked = Key(rawQuestion: query.rawQuestion, hasEDNS: false)
        guard echoed == asked else { return .failure(.questionMismatch) }

        guard let records = try? DNSRecordWalker.walk(response) else { return .failure(.unparseable) }

        let answerTTLs = records.filter { $0.section == .answer && !$0.isOPT }.map(\.ttl)
        let ttl: UInt32
        if rcode == 0, let minimum = answerTTLs.min() {
            ttl = min(minimum, maxPositiveTTL)
        } else {
            var negative = noSOANegativeTTL
            if let soa = records.first(where: { $0.section == .authority && $0.type == DNSRecordType.soa }),
               soa.rdataRange.count >= 4 {
                let end = soa.rdataRange.upperBound
                let minimumField = (UInt32(response[end - 4]) << 24) | (UInt32(response[end - 3]) << 16)
                    | (UInt32(response[end - 2]) << 8) | UInt32(response[end - 1])
                negative = min(minimumField, soa.ttl, maxNegativeTTL)
            }
            ttl = negative
        }
        guard ttl > 0 else { return .failure(.zeroTTL) }
        return .success(ttl)
    }

    /// Drops every entry, bumps the generation and logs at notice.
    /// Returns the number of entries dropped.
    @discardableResult
    public mutating func clear(reason: ClearReason) -> Int {
        let dropped = slots.count
        slots.removeAll()
        totalBytes = 0
        generation &+= 1
        Self.log.notice("cache cleared (\(reason.rawValue)): \(dropped) entries")
        return dropped
    }

    /// Periodic housekeeping: purges expired entries (at most every 60 s) and
    /// emits the throttled eviction and summary log lines. Cheap to call often.
    public mutating func maintain() {
        let current = now()

        if current.timeIntervalSince(lastPurge) >= Self.purgeInterval {
            lastPurge = current
            let expired = slots.compactMap { $0.value.entry.isExpired(at: current) ? $0.key : nil }
            for key in expired { remove(key) }
            if !expired.isEmpty {
                Self.log.debug("cache purged \(expired.count) expired entries")
            }
        }

        if current.timeIntervalSince(lastEvictionLog) >= Self.evictionLogInterval {
            lastEvictionLog = current
            if pendingEvictionsByCount > 0 {
                Self.log.info("cache evicted \(pendingEvictionsByCount) entries (entry limit)")
            }
            if pendingEvictionsByBytes > 0 {
                Self.log.info("cache evicted \(pendingEvictionsByBytes) entries (byte limit)")
            }
            pendingEvictionsByCount = 0
            pendingEvictionsByBytes = 0
        }

        if current.timeIntervalSince(lastSummary) >= Self.summaryInterval {
            lastSummary = current
            let hits = counters.hits - summaryBaseline.hits
            let misses = counters.misses - summaryBaseline.misses
            if hits + misses > 0 {
                let total = counters.hits + counters.misses
                let rate = total == 0 ? 0 : Int(counters.hits * 100 / total)
                let evicted = counters.evictions - summaryBaseline.evictions
                Self.log.info(
                    "cache: \(slots.count) entries, \(totalBytes / 1024) KB, hit rate \(rate)% (hits \(counters.hits), misses \(counters.misses)), evicted \(evicted)")
            }
            summaryBaseline = counters
        }
    }

    private mutating func remove(_ key: Key) {
        if let slot = slots.removeValue(forKey: key) {
            totalBytes -= slot.entry.response.count
        }
    }

    private mutating func evictLeastRecentlyUsed(byBytes: Bool) {
        guard let victim = slots.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key else { return }
        remove(victim)
        counters.evictions += 1
        if byBytes { pendingEvictionsByBytes += 1 } else { pendingEvictionsByCount += 1 }
    }
}
