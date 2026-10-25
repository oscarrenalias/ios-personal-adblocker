import Foundation

/// Decides when a record-by-record resolver (e.g. dns_sd with intermediates)
/// has collected enough to answer. Pure state machine so it can be tested
/// without the platform resolver.
///
/// A CNAME can arrive in its own batch ahead of the target's records, so a
/// batch ending is not enough: the set must contain a record of the asked
/// type (or the question is CNAME/ANY) before completing with records.
public struct DNSQueryCompletion: Sendable {
    public enum NegativeError: Sendable, Equatable {
        case noSuchName     // NXDOMAIN
        case noSuchRecord   // NOERROR / NODATA
    }

    public enum Decision: Sendable, Equatable {
        case keepWaiting
        case complete(rcode: UInt8, records: [DNSResponseBuilder.ResourceRecord])
    }

    private static let typeCNAME: UInt16 = 5
    private static let typeANY: UInt16 = 255

    public let qtype: UInt16
    public private(set) var records: [DNSResponseBuilder.ResourceRecord] = []

    public init(qtype: UInt16) {
        self.qtype = qtype
    }

    public mutating func recordAdded(_ record: DNSResponseBuilder.ResourceRecord) {
        records.append(record)
    }

    /// Called when a callback batch ends (no more records coming right away).
    public func batchEnded() -> Decision {
        hasAnswer ? .complete(rcode: 0, records: records) : .keepWaiting
    }

    /// A negative result keeps any CNAME chain collected so far.
    public func negative(_ error: NegativeError) -> Decision {
        .complete(rcode: error == .noSuchName ? 3 : 0, records: records)
    }

    private var hasAnswer: Bool {
        if qtype == Self.typeCNAME || qtype == Self.typeANY { return !records.isEmpty }
        return records.contains { $0.type == qtype }
    }
}
