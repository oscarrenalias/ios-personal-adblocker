import XCTest
@testable import IBlockerKit

final class QueryLogRecordV2Tests: XCTestCase {

    func testV2RoundTripForEveryRoute() throws {
        let routes: [LogRoute] = [.unknown, .alternative, .network, .networkOnlyName, .fallback, .local]
        for route in routes {
            for cache in [false, true] {
                let record = QueryLogRecord(
                    timestampMillis: 1_700_000_000_000, qtype: 28, verdict: .allowed, listId: 6,
                    domain: "tracker.example.com",
                    details: QueryLogDetails(cacheHit: cache, route: route, sourceNumber: 17, matchedLabels: 3))
                let bytes = record.encoded()
                XCTAssertEqual(bytes.count, 64)
                let decoded = try XCTUnwrap(QueryLogRecord.decode(bytes[...]))
                XCTAssertEqual(decoded, record)
                XCTAssertEqual(decoded.source, 6)
                XCTAssertEqual(decoded.details?.route, route)
                XCTAssertEqual(decoded.details?.cacheHit, cache)
                XCTAssertEqual(decoded.details?.sourceNumber, 17)
                XCTAssertEqual(decoded.details?.matchedLabels, 3)
            }
        }
    }

    func testOldRecordDecodesWithNilDetails() throws {
        var bytes = QueryLogRecord(timestampMillis: 5, qtype: 1, verdict: .blocked, listId: 0,
                                   domain: "old.example.com").encoded()
        XCTAssertEqual(bytes[13], 0)
        XCTAssertEqual(bytes[14], 0)
        XCTAssertEqual(bytes[15], 0)
        let decoded = try XCTUnwrap(QueryLogRecord.decode(bytes[...]))
        XCTAssertNil(decoded.details)
        // Stray detail bytes without the flag bit are ignored.
        bytes[14] = 9; bytes[15] = 9
        XCTAssertNil(QueryLogRecord.decode(bytes[...])?.details)
    }

    func testUnknownRouteWithDetailsBitDecodesAsNil() {
        var bytes = QueryLogRecord(timestampMillis: 5, qtype: 1, verdict: .allowed, domain: "a.example.com",
                                   details: QueryLogDetails()).encoded()
        for raw: UInt8 in 5...7 {
            bytes[13] = 0x80 | raw << 1
            XCTAssertNil(QueryLogRecord.decode(bytes[...]), "route \(raw)")
        }
    }

    func testLongDomainTruncatesButKeepsDetails() throws {
        let domain = String(repeating: "a", count: 60) + ".example.com"
        let record = QueryLogRecord(timestampMillis: 5, qtype: 1, verdict: .blocked, listId: 6, domain: domain,
                                    details: QueryLogDetails(route: .network, sourceNumber: 4, matchedLabels: 2))
        let bytes = record.encoded()
        XCTAssertEqual(bytes.count, QueryLogRecord.recordSize)
        let decoded = try XCTUnwrap(QueryLogRecord.decode(bytes[...]))
        XCTAssertEqual(decoded.domain, String(domain.suffix(48)))
        XCTAssertEqual(decoded.details?.sourceNumber, 4)
        XCTAssertEqual(decoded.details?.matchedLabels, 2)
    }
}
