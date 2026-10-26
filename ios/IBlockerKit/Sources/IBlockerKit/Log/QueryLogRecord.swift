import Foundation

public enum LogVerdict: UInt8, Sendable, Codable {
    case allowed = 0
    case blocked = 1
    case failed = 2
}

/// Route that served a query, as stored in the record flags (bits 1-3).
public enum LogRoute: UInt8, Sendable, Equatable {
    case unknown = 0
    case alternative = 1
    case network = 2
    case networkOnlyName = 3
    case fallback = 4
    case local = 5
}

/// v2 detail fields. Absent on v1 records (flags bit 7 clear).
public struct QueryLogDetails: Sendable, Equatable {
    public var cacheHit: Bool
    public var route: LogRoute
    public var sourceNumber: UInt8
    public var matchedLabels: UInt8

    public init(cacheHit: Bool = false, route: LogRoute = .network,
                sourceNumber: UInt8 = 0, matchedLabels: UInt8 = 0) {
        self.cacheHit = cacheHit
        self.route = route
        self.sourceNumber = sourceNumber
        self.matchedLabels = matchedLabels
    }
}

/// One DNS decision, encoded as a fixed 64-byte record:
///
///     0   timestampMillis  u64 LE
///     8   qtype            u16 LE
///     10  verdict          u8
///     11  source/listId    u8
///     12  domainLen        u8
///     13  flags            u8   (bit0 cache hit, bits1-3 route, bit7 details present)
///     14  sourceNumber     u8   (details only)
///     15  matchedLabels    u8   (details only)
///     16  domain UTF-8, up to 48 bytes, zero padded
public struct QueryLogRecord: Sendable, Equatable {
    public static let recordSize = 64
    public static let maxDomainBytes = 48

    public var timestampMillis: UInt64
    public var qtype: UInt16
    public var verdict: LogVerdict
    public var listId: UInt8
    public var domain: String
    public var details: QueryLogDetails?

    /// Alias for `listId` (byte 11).
    public var source: UInt8 {
        get { listId }
        set { listId = newValue }
    }

    public init(timestampMillis: UInt64, qtype: UInt16, verdict: LogVerdict,
                listId: UInt8 = 0, domain: String, details: QueryLogDetails? = nil) {
        self.details = details
        self.timestampMillis = timestampMillis
        self.qtype = qtype
        self.verdict = verdict
        self.listId = listId
        self.domain = domain
    }

    public var date: Date {
        Date(timeIntervalSince1970: TimeInterval(timestampMillis) / 1000)
    }

    public func encoded() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Self.recordSize)
        var ts = timestampMillis.littleEndian
        withUnsafeBytes(of: &ts) { for (i, b) in $0.enumerated() { out[i] = b } }
        out[8] = UInt8(qtype & 0xFF)
        out[9] = UInt8(qtype >> 8)
        out[10] = verdict.rawValue
        out[11] = listId
        if let d = details {
            out[13] = 0x80 | (d.route.rawValue & 0x07) << 1 | (d.cacheHit ? 1 : 0)
            out[14] = d.sourceNumber
            out[15] = d.matchedLabels
        }

        var domainBytes = Array(domain.utf8)
        if domainBytes.count > Self.maxDomainBytes {
            domainBytes = Array(domainBytes.suffix(Self.maxDomainBytes))
        }
        out[12] = UInt8(domainBytes.count)
        for (i, b) in domainBytes.enumerated() { out[16 + i] = b }
        return out
    }

    /// Decodes one 64-byte slot; returns nil for torn/blank slots.
    public static func decode(_ bytes: ArraySlice<UInt8>) -> QueryLogRecord? {
        guard bytes.count == recordSize else { return nil }
        let b = Array(bytes)

        var ts: UInt64 = 0
        for i in (0..<8).reversed() { ts = ts << 8 | UInt64(b[i]) }
        guard ts != 0 else { return nil }

        let qtype = UInt16(b[8]) | UInt16(b[9]) << 8
        guard let verdict = LogVerdict(rawValue: b[10]) else { return nil }

        let domainLength = Int(b[12])
        guard domainLength > 0, domainLength <= maxDomainBytes else { return nil }
        let domainBytes = Array(b[16..<(16 + domainLength)])
        guard domainBytes.allSatisfy({ $0 >= 0x21 && $0 <= 0x7E }) else { return nil }

        var details: QueryLogDetails?
        if b[13] & 0x80 != 0 {
            guard let route = LogRoute(rawValue: (b[13] >> 1) & 0x07) else { return nil }
            details = QueryLogDetails(cacheHit: b[13] & 1 != 0, route: route,
                                      sourceNumber: b[14], matchedLabels: b[15])
        }

        return QueryLogRecord(
            timestampMillis: ts,
            qtype: qtype,
            verdict: verdict,
            listId: b[11],
            domain: String(decoding: domainBytes, as: UTF8.self),
            details: details
        )
    }
}
