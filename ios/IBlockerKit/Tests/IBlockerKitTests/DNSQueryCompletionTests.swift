import XCTest
@testable import IBlockerKit

final class DNSQueryCompletionTests: XCTestCase {
    private func rr(_ type: UInt16, _ tag: UInt8) -> DNSResponseBuilder.ResourceRecord {
        .init(name: [1, 97, 0], type: type, class: 1, ttl: 60, rdata: [tag])
    }

    func testCNAMEBatchThenABatchYieldsBothInOrder() {
        var c = DNSQueryCompletion(qtype: 1)
        let cname = rr(5, 1), a = rr(1, 2)
        c.recordAdded(cname)
        XCTAssertEqual(c.batchEnded(), .keepWaiting)
        c.recordAdded(a)
        XCTAssertEqual(c.batchEnded(), .complete(rcode: 0, records: [cname, a]))
    }

    func testCNAMEOnlyForATypeKeepsWaiting() {
        var c = DNSQueryCompletion(qtype: 1)
        c.recordAdded(rr(5, 1))
        XCTAssertEqual(c.batchEnded(), .keepWaiting)
    }

    func testEmptyBatchKeepsWaiting() {
        XCTAssertEqual(DNSQueryCompletion(qtype: 1).batchEnded(), .keepWaiting)
    }

    func testCNAMEQueryCompletesOnCNAME() {
        var c = DNSQueryCompletion(qtype: 5)
        let cname = rr(5, 1)
        c.recordAdded(cname)
        XCTAssertEqual(c.batchEnded(), .complete(rcode: 0, records: [cname]))
    }

    func testANYQueryCompletesOnAnyRecord() {
        var c = DNSQueryCompletion(qtype: 255)
        let cname = rr(5, 1)
        c.recordAdded(cname)
        XCTAssertEqual(c.batchEnded(), .complete(rcode: 0, records: [cname]))
    }

    func testCNAMEThenNoSuchRecordIsNoErrorWithChain() {
        var c = DNSQueryCompletion(qtype: 28)
        let cname = rr(5, 1)
        c.recordAdded(cname)
        XCTAssertEqual(c.negative(.noSuchRecord), .complete(rcode: 0, records: [cname]))
    }

    func testCNAMEThenNoSuchNameIsNXDOMAINWithChain() {
        var c = DNSQueryCompletion(qtype: 1)
        let cname = rr(5, 1)
        c.recordAdded(cname)
        XCTAssertEqual(c.negative(.noSuchName), .complete(rcode: 3, records: [cname]))
    }

    func testNoSuchNameWithNothingCollected() {
        XCTAssertEqual(DNSQueryCompletion(qtype: 1).negative(.noSuchName),
                       .complete(rcode: 3, records: []))
    }
}
