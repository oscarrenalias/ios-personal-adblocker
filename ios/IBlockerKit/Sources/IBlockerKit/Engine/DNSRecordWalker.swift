import Foundation

/// Section of a DNS message a record belongs to.
enum DNSSection: Equatable {
    case answer
    case authority
    case additional
}

/// One resource record located inside a DNS message.
struct DNSRecordInfo: Equatable {
    let section: DNSSection
    /// RR TYPE (e.g. 1 = A, 5 = CNAME, 41 = OPT).
    let type: UInt16
    /// RR CLASS (for OPT records this is the UDP payload size).
    let rrClass: UInt16
    /// Byte offset of the 4-byte TTL field within the message.
    let ttlOffset: Int
    let ttl: UInt32
    /// Byte range of the RDATA within the message.
    let rdataRange: Range<Int>

    static let optType: UInt16 = 41

    /// OPT pseudo-records carry EDNS data; their "TTL" is not a real TTL.
    var isOPT: Bool { type == DNSRecordInfo.optType }
}

/// Iterates the answer, authority and additional records of a DNS message.
/// Pure parsing: malformed input throws `DNSWireError` and nothing is logged.
enum DNSRecordWalker {

    private static let headerLength = 12

    /// Returns every resource record in message order (answer, authority,
    /// additional). Question entries are skipped. Throws on truncated or
    /// malformed input, including record counts that exceed the data.
    static func walk(_ bytes: [UInt8]) throws -> [DNSRecordInfo] {
        guard bytes.count >= headerLength else { throw DNSWireError.truncated }

        let qd = readUInt16(bytes, 4)
        let an = readUInt16(bytes, 6)
        let ns = readUInt16(bytes, 8)
        let ar = readUInt16(bytes, 10)

        var offset = headerLength

        for _ in 0..<qd {
            offset = try skipName(bytes, at: offset)
            guard offset + 4 <= bytes.count else { throw DNSWireError.truncated }
            offset += 4
        }

        var records: [DNSRecordInfo] = []
        let sections: [(DNSSection, Int)] = [(.answer, an), (.authority, ns), (.additional, ar)]
        for (section, count) in sections {
            for _ in 0..<count {
                offset = try skipName(bytes, at: offset)
                guard offset + 10 <= bytes.count else { throw DNSWireError.truncated }
                let type = UInt16(readUInt16(bytes, offset))
                let rrClass = UInt16(readUInt16(bytes, offset + 2))
                let ttlOffset = offset + 4
                let ttl = (UInt32(bytes[ttlOffset]) << 24)
                    | (UInt32(bytes[ttlOffset + 1]) << 16)
                    | (UInt32(bytes[ttlOffset + 2]) << 8)
                    | UInt32(bytes[ttlOffset + 3])
                let rdLength = readUInt16(bytes, offset + 8)
                let rdStart = offset + 10
                let rdEnd = rdStart + rdLength
                guard rdEnd <= bytes.count else { throw DNSWireError.truncated }
                records.append(DNSRecordInfo(
                    section: section,
                    type: type,
                    rrClass: rrClass,
                    ttlOffset: ttlOffset,
                    ttl: ttl,
                    rdataRange: rdStart..<rdEnd))
                offset = rdEnd
            }
        }
        return records
    }

    /// Returns the offset just past the (possibly compressed) name at `offset`.
    /// Pointers are not followed: a pointer always terminates the name in place.
    static func skipName(_ bytes: [UInt8], at offset: Int) throws -> Int {
        var i = offset
        var nameBytes = 0
        while true {
            guard i < bytes.count else { throw DNSWireError.truncated }
            let len = Int(bytes[i])
            if len == 0 { return i + 1 }
            if len & 0xC0 == 0xC0 {
                guard i + 1 < bytes.count else { throw DNSWireError.truncated }
                return i + 2
            }
            guard len & 0xC0 == 0 else { throw DNSWireError.badLabel }
            guard i + 1 + len <= bytes.count else { throw DNSWireError.truncated }
            nameBytes += len + 1
            guard nameBytes <= 255 else { throw DNSWireError.nameTooLong }
            i += len + 1
        }
    }

    private static func readUInt16(_ bytes: [UInt8], _ at: Int) -> Int {
        (Int(bytes[at]) << 8) | Int(bytes[at + 1])
    }
}
