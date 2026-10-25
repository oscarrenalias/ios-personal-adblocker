import XCTest
@testable import IBlockerKit

final class DNSResponseBuilderTests: XCTestCase {

    private func parseQuery(_ name: String, qtype: UInt16, id: UInt16 = 0x4242) throws -> DNSQuery {
        try DNSParser.parseQuery(makeDNSQueryData(id: id, name: name, qtype: qtype))
    }

    func testBlockedAReturnsZeroAddress() throws {
        let query = try parseQuery("ads.example.com", qtype: DNSRecordType.a)
        let response = try XCTUnwrap(MiniDNSResponse(DNSResponseBuilder.blocked(for: query)))

        XCTAssertEqual(response.id, 0x4242)
        XCTAssertTrue(response.isResponse)
        XCTAssertTrue(response.recursionAvailable)
        XCTAssertFalse(response.isTruncated)
        XCTAssertEqual(response.rcode, 0)
        XCTAssertEqual(response.qdcount, 1)
        XCTAssertEqual(response.ancount, 1)
        XCTAssertEqual(response.questionName, "ads.example.com")
        XCTAssertEqual(response.answerType, DNSRecordType.a)
        XCTAssertEqual(response.answerRData, [0, 0, 0, 0])
    }

    func testBlockedAAAAReturnsZeroAddress() throws {
        let query = try parseQuery("ads.example.com", qtype: DNSRecordType.aaaa)
        let response = try XCTUnwrap(MiniDNSResponse(DNSResponseBuilder.blocked(for: query)))
        XCTAssertEqual(response.ancount, 1)
        XCTAssertEqual(response.answerType, DNSRecordType.aaaa)
        XCTAssertEqual(response.answerRData, [UInt8](repeating: 0, count: 16))
    }

    func testBlockedHTTPSTypeReturnsNoData() throws {
        // HTTPS (type 65) records carry address hints; answering NODATA
        // instead of ignoring them is what keeps modern Safari from leaking.
        let query = try parseQuery("ads.example.com", qtype: DNSRecordType.https)
        let response = try XCTUnwrap(MiniDNSResponse(DNSResponseBuilder.blocked(for: query)))
        XCTAssertEqual(response.rcode, 0)
        XCTAssertEqual(response.ancount, 0)
    }

    func testNXDomainAndServfailAndTruncated() throws {
        let query = try parseQuery("x.example.com", qtype: DNSRecordType.a)
        XCTAssertEqual(MiniDNSResponse(DNSResponseBuilder.nxdomain(for: query))?.rcode, 3)
        XCTAssertEqual(MiniDNSResponse(DNSResponseBuilder.servfail(for: query))?.rcode, 2)
        let truncated = try XCTUnwrap(MiniDNSResponse(DNSResponseBuilder.truncated(for: query)))
        XCTAssertTrue(truncated.isTruncated)
        XCTAssertEqual(truncated.ancount, 0)
    }

    func testQuestionEchoIsByteExact() throws {
        let data = makeDNSQueryData(id: 1, name: "AdS.ExAmPle.CoM", qtype: DNSRecordType.a)
        let query = try DNSParser.parseQuery(data)
        let response = DNSResponseBuilder.blocked(for: query)
        let echoed = [UInt8](response)[12..<(12 + query.rawQuestion.count)]
        XCTAssertEqual(Array(echoed), query.rawQuestion)
    }

    func testRecursionDesiredIsEchoed() throws {
        let noRD = try DNSParser.parseQuery(makeDNSQueryData(name: "a.example.com", recursionDesired: false))
        let response = try XCTUnwrap(MiniDNSResponse(DNSResponseBuilder.blocked(for: noRD)))
        XCTAssertEqual(response.flags & 0x0100, 0)
    }

    func testResponseParsesWithOwnParserAsResponse() throws {
        // Our own parser must reject what we emit (QR=1) — guards loops.
        let query = try parseQuery("ads.example.com", qtype: DNSRecordType.a)
        XCTAssertThrowsError(try DNSParser.parseQuery(DNSResponseBuilder.blocked(for: query)))
    }

    // MARK: - response(for:rcode:records:)

    private func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) << 8 | UInt16(b[i + 1]) }

    func testResponseWithRecordsHeaderAndQuestion() throws {
        let data = makeDNSQueryData(id: 0xBEEF, name: "WwW.ExAmPle.CoM", qtype: DNSRecordType.a, recursionDesired: true)
        let query = try DNSParser.parseQuery(data)
        let record = DNSResponseBuilder.ResourceRecord(
            name: [0xC0, 0x0C], type: DNSRecordType.a, class: 1, ttl: 60, rdata: [1, 2, 3, 4])
        let bytes = [UInt8](DNSResponseBuilder.response(for: query, rcode: 0, records: [record, record]))

        XCTAssertEqual(u16(bytes, 0), 0xBEEF)
        let flags = u16(bytes, 2)
        XCTAssertNotEqual(flags & 0x8000, 0, "QR")
        XCTAssertEqual(flags & 0x0100, 0x0100, "RD mirrored")
        XCTAssertNotEqual(flags & 0x0080, 0, "RA")
        XCTAssertEqual(flags & 0x0400, 0, "AA")
        XCTAssertEqual(flags & 0x0200, 0, "TC")
        XCTAssertEqual(flags & 0x000F, 0)
        XCTAssertEqual(u16(bytes, 4), 1)
        XCTAssertEqual(u16(bytes, 6), 2)
        XCTAssertEqual(u16(bytes, 8), 0)
        XCTAssertEqual(u16(bytes, 10), 0)
        let q = query.rawQuestion.count
        XCTAssertEqual(Array(bytes[12..<(12 + q)]), query.rawQuestion)
        XCTAssertEqual(Array(bytes[12..<(12 + q)]).contains(UInt8(ascii: "W")), true, "mixed case preserved")
    }

    func testResponseRDIsMirroredWhenClear() throws {
        let query = try DNSParser.parseQuery(makeDNSQueryData(name: "a.example.com", recursionDesired: false))
        let bytes = [UInt8](DNSResponseBuilder.response(for: query, rcode: 0, records: []))
        XCTAssertEqual(u16(bytes, 2) & 0x0100, 0)
        XCTAssertNotEqual(u16(bytes, 2) & 0x0080, 0)
    }

    func testResponseCNAMEThenARecordOrderAndRData() throws {
        let query = try DNSParser.parseQuery(makeDNSQueryData(name: "www.example.com"))
        let target: [UInt8] = [3, 99, 100, 110, 7, 101, 120, 97, 109, 112, 108, 101, 3, 99, 111, 109, 0]
        let cname = DNSResponseBuilder.ResourceRecord(
            name: [0xC0, 0x0C], type: 5, class: 1, ttl: 0x01020304, rdata: target)
        let a = DNSResponseBuilder.ResourceRecord(
            name: target, type: DNSRecordType.a, class: 1, ttl: 30, rdata: [192, 0, 2, 7])
        let bytes = [UInt8](DNSResponseBuilder.response(for: query, rcode: 0, records: [cname, a]))
        XCTAssertEqual(u16(bytes, 6), 2)

        var i = 12 + query.rawQuestion.count
        XCTAssertEqual(Array(bytes[i..<(i + 2)]), [0xC0, 0x0C]); i += 2
        XCTAssertEqual(u16(bytes, i), 5); i += 2
        XCTAssertEqual(u16(bytes, i), 1); i += 2
        XCTAssertEqual(Array(bytes[i..<(i + 4)]), [1, 2, 3, 4]); i += 4
        XCTAssertEqual(Int(u16(bytes, i)), target.count); i += 2
        XCTAssertEqual(Array(bytes[i..<(i + target.count)]), target); i += target.count

        XCTAssertEqual(Array(bytes[i..<(i + target.count)]), target); i += target.count
        XCTAssertEqual(u16(bytes, i), DNSRecordType.a); i += 2
        XCTAssertEqual(u16(bytes, i), 1); i += 2
        XCTAssertEqual(Array(bytes[i..<(i + 4)]), [0, 0, 0, 30]); i += 4
        XCTAssertEqual(u16(bytes, i), 4); i += 2
        XCTAssertEqual(Array(bytes[i..<(i + 4)]), [192, 0, 2, 7]); i += 4
        XCTAssertEqual(i, bytes.count)
    }

    func testResponseNXDomainAndNoData() throws {
        let query = try parseQuery("x.example.com", qtype: DNSRecordType.a)
        let nx = try XCTUnwrap(MiniDNSResponse(DNSResponseBuilder.response(for: query, rcode: 3, records: [])))
        XCTAssertEqual(nx.rcode, 3)
        XCTAssertEqual(nx.ancount, 0)
        let nodata = try XCTUnwrap(MiniDNSResponse(DNSResponseBuilder.response(for: query, rcode: 0, records: [])))
        XCTAssertEqual(nodata.rcode, 0)
        XCTAssertEqual(nodata.ancount, 0)
    }
}
