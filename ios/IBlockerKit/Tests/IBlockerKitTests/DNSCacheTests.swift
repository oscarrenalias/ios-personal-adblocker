import XCTest
@testable import IBlockerKit

// MARK: - Helpers

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

private struct TestRR {
    var type: UInt16
    var ttl: UInt32
    var rdata: [UInt8]
    var rrClass: UInt16 = 1
    var name: [UInt8] = [0xC0, 0x0C]

    static func a(ttl: UInt32, _ addr: [UInt8] = [1, 2, 3, 4]) -> TestRR {
        TestRR(type: 1, ttl: ttl, rdata: addr)
    }
    static func cname(ttl: UInt32) -> TestRR {
        TestRR(type: 5, ttl: ttl, rdata: [3, 0x63, 0x64, 0x6E, 0])
    }
    static func ns(ttl: UInt32) -> TestRR {
        TestRR(type: 2, ttl: ttl, rdata: [2, 0x6E, 0x73, 0])
    }
    /// SOA with empty MNAME/RNAME and the given MINIMUM field.
    static func soa(ttl: UInt32, minimum: UInt32) -> TestRR {
        let fields = [UInt8](repeating: 0, count: 16)
        let min: [UInt8] = [UInt8(minimum >> 24), UInt8((minimum >> 16) & 0xFF),
                            UInt8((minimum >> 8) & 0xFF), UInt8(minimum & 0xFF)]
        return TestRR(type: 6, ttl: ttl, rdata: [0, 0] + fields + min)
    }
    static func opt(ttlField: UInt32) -> TestRR {
        TestRR(type: 41, ttl: ttlField, rdata: [], rrClass: 4096, name: [0])
    }
}

private func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
private func be32(_ v: UInt32) -> [UInt8] {
    [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
}

private func makeResponse(for queryData: Data, rcode: UInt8 = 0, extraFlags: UInt16 = 0,
                          answers: [TestRR] = [], authority: [TestRR] = [], additional: [TestRR] = [],
                          questionOverride: [UInt8]? = nil, qdcount: UInt16 = 1) throws -> [UInt8] {
    let query = try DNSParser.parseQuery(queryData)
    let flags: UInt16 = 0x8180 | UInt16(rcode) | extraFlags
    var out: [UInt8] = be16(query.transactionID) + be16(flags) + be16(qdcount)
        + be16(UInt16(answers.count)) + be16(UInt16(authority.count)) + be16(UInt16(additional.count))
    if qdcount > 0 { out += questionOverride ?? query.rawQuestion }
    for rr in answers + authority + additional {
        out += rr.name + be16(rr.type) + be16(rr.rrClass) + be32(rr.ttl) + be16(UInt16(rr.rdata.count)) + rr.rdata
    }
    return out
}

private func query(_ name: String, id: UInt16 = 0x1234, qtype: UInt16 = DNSRecordType.a,
                   edns: Bool = false, rd: Bool = true) -> Data {
    makeDNSQueryData(id: id, name: name, qtype: qtype, recursionDesired: rd, edns: edns)
}

private func parsed(_ data: Data) throws -> DNSQuery { try DNSParser.parseQuery(data) }

private func recordTTLs(_ bytes: [UInt8]) throws -> [(section: DNSSection, type: UInt16, ttl: UInt32)] {
    try DNSRecordWalker.walk(bytes).map { ($0.section, $0.type, $0.ttl) }
}

private func hitBytes(_ result: DNSCache.LookupResult, file: StaticString = #filePath, line: UInt = #line) -> [UInt8]? {
    guard case .hit(let data) = result else {
        XCTFail("expected a cache hit, got \(result)", file: file, line: line)
        return nil
    }
    return [UInt8](data)
}

private func isMiss(_ result: DNSCache.LookupResult) -> Bool {
    if case .miss = result { return true }
    return false
}

private func isBypass(_ result: DNSCache.LookupResult) -> Bool {
    if case .bypass = result { return true }
    return false
}

// MARK: - DNSCache unit tests

final class DNSCacheTests: XCTestCase {

    private var clock: TestClock!

    override func setUp() {
        clock = TestClock()
    }

    private func makeCache(maxEntries: Int = DNSCache.maxEntries, maxBytes: Int = DNSCache.maxBytes) -> DNSCache {
        let clock = self.clock!
        return DNSCache(maxEntries: maxEntries, maxBytes: maxBytes, now: { clock.now })
    }

    private func ttl(_ q: Data, _ response: [UInt8]) throws -> Result<UInt32, DNSCache.NotCacheable> {
        DNSCache.entryTTL(query: try parsed(q), response: response)
    }

    // MARK: TTL rules

    func testPositiveTTLIsMinimumAnswerTTL() throws {
        let q = query("example.com")
        let r = try makeResponse(for: q, answers: [.a(ttl: 300), .a(ttl: 120, [5, 6, 7, 8])])
        XCTAssertEqual(try ttl(q, r), .success(120))
    }

    func testPositiveTTLThroughCNAMEChainUsesMinimum() throws {
        let q = query("www.example.com")
        let r = try makeResponse(for: q, answers: [.cname(ttl: 100), .a(ttl: 3000)])
        XCTAssertEqual(try ttl(q, r), .success(100))
        let r2 = try makeResponse(for: q, answers: [.cname(ttl: 3000), .a(ttl: 45)])
        XCTAssertEqual(try ttl(q, r2), .success(45))
    }

    func testPositiveTTLCappedAtOneHour() throws {
        let q = query("example.com")
        let r = try makeResponse(for: q, answers: [.a(ttl: 86_400)])
        XCTAssertEqual(try ttl(q, r), .success(3_600))
    }

    func testOPTRecordDoesNotInfluenceTTL() throws {
        let q = query("example.com")
        let r = try makeResponse(for: q, answers: [.a(ttl: 500)], additional: [.opt(ttlField: 0)])
        XCTAssertEqual(try ttl(q, r), .success(500))
    }

    func testNegativeTTLIsMinOfSOAMinimumSOATTLAndCap() throws {
        let q = query("nope.example.com")
        // Both large → capped at 300.
        let capped = try makeResponse(for: q, rcode: 3, authority: [.soa(ttl: 900, minimum: 600)])
        XCTAssertEqual(try ttl(q, capped), .success(300))
        // SOA record TTL is the lowest.
        let ttlLow = try makeResponse(for: q, rcode: 3, authority: [.soa(ttl: 100, minimum: 600)])
        XCTAssertEqual(try ttl(q, ttlLow), .success(100))
        // SOA MINIMUM field is the lowest.
        let minLow = try makeResponse(for: q, rcode: 3, authority: [.soa(ttl: 900, minimum: 50)])
        XCTAssertEqual(try ttl(q, minLow), .success(50))
    }

    func testNODATAUsesNegativeRules() throws {
        let q = query("example.com", qtype: DNSRecordType.aaaa)
        let r = try makeResponse(for: q, authority: [.soa(ttl: 60, minimum: 90)])
        XCTAssertEqual(try ttl(q, r), .success(60))
    }

    func testNegativeWithoutSOAFallsBackTo30Seconds() throws {
        let q = query("nope.example.com")
        XCTAssertEqual(try ttl(q, try makeResponse(for: q, rcode: 3)), .success(30))
        XCTAssertEqual(try ttl(q, try makeResponse(for: q)), .success(30))
    }

    func testZeroTTLIsNotCached() throws {
        var cache = makeCache()
        let q = query("example.com")
        let r = try makeResponse(for: q, answers: [.a(ttl: 0)])
        XCTAssertEqual(try ttl(q, r), .failure(.zeroTTL))
        XCTAssertFalse(cache.store(query: try parsed(q), response: Data(r)))
        XCTAssertEqual(cache.entryCount, 0)

        let neg = try makeResponse(for: q, rcode: 3, authority: [.soa(ttl: 300, minimum: 0)])
        XCTAssertEqual(try ttl(q, neg), .failure(.zeroTTL))
        // A zero among several answer TTLs wins as the minimum.
        let mixed = try makeResponse(for: q, answers: [.a(ttl: 0), .a(ttl: 60)])
        XCTAssertEqual(try ttl(q, mixed), .failure(.zeroTTL))
    }

    func testServfailRefusedTruncatedAndMismatchAreNotCached() throws {
        var cache = makeCache()
        let q = query("example.com")
        let pq = try parsed(q)

        let servfail = try makeResponse(for: q, rcode: 2)
        XCTAssertEqual(try ttl(q, servfail), .failure(.rcode(2)))
        let refused = try makeResponse(for: q, rcode: 5)
        XCTAssertEqual(try ttl(q, refused), .failure(.rcode(5)))
        let tc = try makeResponse(for: q, extraFlags: 0x0200, answers: [.a(ttl: 300)])
        XCTAssertEqual(try ttl(q, tc), .failure(.truncated))

        let other = try parsed(query("other.example.com")).rawQuestion
        let mismatch = try makeResponse(for: q, answers: [.a(ttl: 300)], questionOverride: other)
        XCTAssertEqual(try ttl(q, mismatch), .failure(.questionMismatch))
        let noQuestion = try makeResponse(for: q, answers: [.a(ttl: 300)], qdcount: 0)
        XCTAssertEqual(try ttl(q, noQuestion), .failure(.questionMismatch))
        // Different qtype for the same name is a mismatch too.
        let aaaa = try parsed(query("example.com", qtype: DNSRecordType.aaaa)).rawQuestion
        let wrongType = try makeResponse(for: q, answers: [.a(ttl: 300)], questionOverride: aaaa)
        XCTAssertEqual(try ttl(q, wrongType), .failure(.questionMismatch))

        for bad in [servfail, refused, tc, mismatch, noQuestion, wrongType] {
            XCTAssertFalse(cache.store(query: pq, response: Data(bad)))
        }
        XCTAssertEqual(cache.entryCount, 0)
    }

    func testQueryAndGarbageResponsesAreNotCached() throws {
        let q = query("example.com")
        // A query-shaped message (QR=0).
        var notResponse = try makeResponse(for: q, answers: [.a(ttl: 300)])
        notResponse[2] &= 0x7F
        XCTAssertEqual(try ttl(q, notResponse), .failure(.notAResponse))
        XCTAssertEqual(try ttl(q, [1, 2, 3]), .failure(.unparseable))
        // Record count claims more than the bytes hold.
        var truncated = try makeResponse(for: q, answers: [.a(ttl: 300)])
        truncated.removeLast(3)
        XCTAssertEqual(try ttl(q, truncated), .failure(.unparseable))
        // Over the response size cap.
        var big = try makeResponse(for: q, answers: [.a(ttl: 300)])
        big += [UInt8](repeating: 0, count: DNSCache.maxResponseBytes)
        XCTAssertEqual(try ttl(q, big), .failure(.tooLarge))
    }

    func testStoreByQueryThenHit() throws {
        var cache = makeCache()
        let q = query("example.com")
        let r = try makeResponse(for: q, answers: [.a(ttl: 300)])
        XCTAssertTrue(cache.store(query: try parsed(q), response: Data(r)))
        XCTAssertEqual(cache.entryCount, 1)
        XCTAssertEqual(cache.byteCount, r.count)
        XCTAssertNotNil(hitBytes(cache.lookup(query: try parsed(q))))
    }

    // MARK: Expiry

    func testEntryExpiresAtItsTTL() throws {
        var cache = makeCache()
        let q = try parsed(query("example.com"))
        let r = try makeResponse(for: query("example.com"), answers: [.a(ttl: 10)])
        XCTAssertTrue(cache.store(query: q, response: Data(r)))

        clock.advance(9)
        XCTAssertNotNil(hitBytes(cache.lookup(query: q)))
        clock.advance(1)
        XCTAssertTrue(isMiss(cache.lookup(query: q)))
        XCTAssertEqual(cache.entryCount, 0, "expired entry is removed on lookup")
        XCTAssertEqual(cache.byteCount, 0)
        XCTAssertEqual(cache.counters.hits, 1)
        XCTAssertEqual(cache.counters.misses, 1)
    }

    func testMaintainPurgesExpiredEntriesAfterPurgeInterval() throws {
        var cache = makeCache()
        let q = try parsed(query("example.com"))
        let r = try makeResponse(for: query("example.com"), answers: [.a(ttl: 5)])
        cache.store(query: q, response: Data(r))
        clock.advance(30)
        cache.maintain()
        XCTAssertEqual(cache.entryCount, 1, "purge runs at most every 60 s")
        clock.advance(31)
        cache.maintain()
        XCTAssertEqual(cache.entryCount, 0)
        XCTAssertEqual(cache.byteCount, 0)
    }

    func testRawLookupHonoursExpiry() {
        var cache = makeCache()
        let key = DNSCache.Key(rawQuestion: [1, 0x61, 0, 0, 1, 0, 1], hasEDNS: false)
        XCTAssertTrue(cache.store(key, response: [1, 2, 3], entryTTL: 2))
        XCTAssertNotNil(cache.lookup(key))
        clock.advance(2)
        XCTAssertNil(cache.lookup(key))
        XCTAssertFalse(cache.store(key, response: [1], entryTTL: 0))
    }

    // MARK: Rewrite

    func testHitRewritesTransactionIDQuestionCaseAndRD() throws {
        var cache = makeCache()
        let q1 = query("www.example.com", id: 0x1111)
        cache.store(query: try parsed(q1), response: Data(try makeResponse(for: q1, answers: [.a(ttl: 300)])))

        // Same name with 0x20-style random casing, new ID, RD clear.
        let q2 = query("wWw.ExAmPlE.cOm", id: 0xBEEF, rd: false)
        let pq2 = try parsed(q2)
        let out = try XCTUnwrap(hitBytes(cache.lookup(query: pq2)))

        XCTAssertEqual(Array(out[0..<2]), [0xBE, 0xEF])
        XCTAssertEqual(Array(out[12..<(12 + pq2.rawQuestion.count)]), pq2.rawQuestion)
        XCTAssertEqual(out[2] & 0x01, 0, "RD mirrors the new query")
        XCTAssertEqual(out[2] & 0x80, 0x80, "still a response")
        let parsedResponse = try XCTUnwrap(MiniDNSResponse(Data(out)))
        XCTAssertEqual(parsedResponse.answerRData, [1, 2, 3, 4])

        // RD set on a later query is reflected too.
        let out2 = try XCTUnwrap(hitBytes(cache.lookup(query: try parsed(query("www.example.com", id: 7, rd: true)))))
        XCTAssertEqual(out2[2] & 0x01, 1)
    }

    func testHitRewritesRemainingTTLInAllSectionsAndLeavesOPTAlone() throws {
        var cache = makeCache()
        let q = query("example.com")
        let optField: UInt32 = 0x0012_3456
        let r = try makeResponse(
            for: q,
            answers: [.cname(ttl: 300), .a(ttl: 60)],
            authority: [.ns(ttl: 500)],
            additional: [.a(ttl: 120, [9, 9, 9, 9]), .opt(ttlField: optField)])
        XCTAssertTrue(cache.store(query: try parsed(q), response: Data(r)))

        // Entry TTL is 60 (the minimum answer TTL); 20 s later all real records say 40.
        clock.advance(20)
        let out = try XCTUnwrap(hitBytes(cache.lookup(query: try parsed(q))))
        let ttls = try recordTTLs(out)
        XCTAssertEqual(ttls.count, 5)
        for rr in ttls where rr.type != 41 {
            XCTAssertEqual(rr.ttl, 40, "section \(rr.section) type \(rr.type)")
        }
        XCTAssertEqual(ttls.first(where: { $0.type == 41 })?.ttl, optField, "OPT TTL field is not a TTL")
        XCTAssertEqual(Set(ttls.map(\.section)), [.answer, .authority, .additional])
    }

    func testRewrittenTTLNeverBelowOneAndNeverAboveOriginal() throws {
        var cache = makeCache()
        let q = query("example.com")
        // Entry TTL 60; one record has a shorter TTL of 10.
        let r = try makeResponse(for: q, answers: [.a(ttl: 60), .a(ttl: 10, [5, 5, 5, 5])])
        // minimum is 10 → entry TTL 10.
        cache.store(query: try parsed(q), response: Data(r))
        clock.advance(9)
        let out = try XCTUnwrap(hitBytes(cache.lookup(query: try parsed(q))))
        XCTAssertEqual(try recordTTLs(out).map(\.ttl), [1, 1])

        // At age 0 the TTLs are unchanged (capped by the entry TTL).
        var fresh = makeCache()
        let r2 = try makeResponse(for: q, answers: [.a(ttl: 300)], authority: [.ns(ttl: 3000)])
        fresh.store(query: try parsed(q), response: Data(r2))
        let out2 = try XCTUnwrap(hitBytes(fresh.lookup(query: try parsed(q))))
        XCTAssertEqual(try recordTTLs(out2).map(\.ttl), [300, 300])
    }

    func testNegativeHitCountsDownFromNegativeTTL() throws {
        var cache = makeCache()
        let q = query("nope.example.com")
        let r = try makeResponse(for: q, rcode: 3, authority: [.soa(ttl: 900, minimum: 600)])
        cache.store(query: try parsed(q), response: Data(r))
        clock.advance(100)
        let out = try XCTUnwrap(hitBytes(cache.lookup(query: try parsed(q))))
        XCTAssertEqual(out[3] & 0x0F, 3, "NXDOMAIN preserved")
        XCTAssertEqual(try recordTTLs(out).map(\.ttl), [200])
    }

    func testStoredBytesAreNotMutatedByHits() throws {
        var cache = makeCache()
        let q = query("example.com", id: 1)
        let r = try makeResponse(for: q, answers: [.a(ttl: 300)])
        cache.store(query: try parsed(q), response: Data(r))
        clock.advance(100)
        _ = cache.lookup(query: try parsed(query("EXAMPLE.com", id: 2)))
        clock.advance(50)
        let out = try XCTUnwrap(hitBytes(cache.lookup(query: try parsed(query("example.com", id: 3)))))
        XCTAssertEqual(try recordTTLs(out).map(\.ttl), [150])
        XCTAssertEqual(Array(out[0..<2]), [0, 3])
    }

    // MARK: Keys

    func testKeyFoldsNameCaseOnly() throws {
        let lower = try parsed(query("example.com"))
        let mixed = try parsed(query("ExAmPlE.CoM"))
        XCTAssertNotEqual(lower.rawQuestion, mixed.rawQuestion)
        XCTAssertEqual(DNSCache.Key(rawQuestion: lower.rawQuestion, hasEDNS: false),
                       DNSCache.Key(rawQuestion: mixed.rawQuestion, hasEDNS: false))
    }

    func testKeyDoesNotFoldQtypeBytes() throws {
        // qtype 65 is 0x0041 and 97 is 0x0061: only name bytes may be folded.
        let t65 = try parsed(query("example.com", qtype: 65))
        let t97 = try parsed(query("example.com", qtype: 97))
        XCTAssertNotEqual(DNSCache.Key(rawQuestion: t65.rawQuestion, hasEDNS: false),
                          DNSCache.Key(rawQuestion: t97.rawQuestion, hasEDNS: false))
    }

    func testDifferentTypesAndNamesAreSeparateEntries() throws {
        var cache = makeCache()
        for (name, type) in [("example.com", DNSRecordType.a), ("example.com", DNSRecordType.aaaa),
                             ("other.com", DNSRecordType.a)] {
            let q = query(name, qtype: type)
            XCTAssertTrue(cache.store(query: try parsed(q), response: Data(try makeResponse(for: q, answers: [.a(ttl: 60)]))))
        }
        XCTAssertEqual(cache.entryCount, 3)
    }

    func testEDNSAndPlainQueriesUseSeparateEntries() throws {
        var cache = makeCache()
        let plain = query("example.com")
        let edns = query("example.com", edns: true)

        cache.store(query: try parsed(plain), response: Data(try makeResponse(for: plain, answers: [.a(ttl: 60)])))
        XCTAssertTrue(isMiss(cache.lookup(query: try parsed(edns))), "plain entry must not serve an EDNS query")

        cache.store(query: try parsed(edns), response: Data(try makeResponse(for: edns, answers: [.a(ttl: 60)],
                                                                             additional: [.opt(ttlField: 0)])))
        XCTAssertEqual(cache.entryCount, 2)
        XCTAssertNotNil(hitBytes(cache.lookup(query: try parsed(plain))))
        let ednsHit = try XCTUnwrap(hitBytes(cache.lookup(query: try parsed(edns))))
        XCTAssertEqual(try recordTTLs(ednsHit).filter { $0.type == 41 }.count, 1)
    }

    // MARK: Bypass

    func testCDDOAndNonINQueriesBypassWithoutCounting() throws {
        var cache = makeCache()
        let base = query("example.com")
        let r = try makeResponse(for: base, answers: [.a(ttl: 300)])
        XCTAssertTrue(cache.store(query: try parsed(base), response: Data(r)))
        let before = cache.counters

        var cd = [UInt8](base)
        cd[3] |= 0x10
        var doBit = [UInt8](query("example.com", edns: true))
        doBit[doBit.count - 6 + 2] = 0x80      // OPT TTL field: DO flag
        var chaos = [UInt8](base)
        chaos[chaos.count - 1] = 3             // qclass CH

        for (label, bytes) in [("CD", cd), ("DO", doBit), ("class", chaos)] {
            let q = try parsed(Data(bytes))
            XCTAssertTrue(isBypass(cache.lookup(query: q)), label)
            XCTAssertFalse(cache.store(query: q, response: Data(r)), label)
        }
        XCTAssertEqual(cache.counters, before, "bypassed queries are neither hit nor miss")
        XCTAssertEqual(cache.entryCount, 1)
    }

    func testEDNSWithoutDOIsCacheable() throws {
        var cache = makeCache()
        let q = query("example.com", edns: true)
        XCTAssertTrue(cache.store(query: try parsed(q), response: Data(try makeResponse(for: q, answers: [.a(ttl: 60)]))))
        XCTAssertNotNil(hitBytes(cache.lookup(query: try parsed(q))))
    }

    // MARK: LRU

    private func key(_ name: String) -> DNSCache.Key {
        let q = try! parsed(query(name))
        return DNSCache.Key(rawQuestion: q.rawQuestion, hasEDNS: false)
    }

    func testLRUEvictionByEntryCount() {
        var cache = makeCache(maxEntries: 3)
        for name in ["a.com", "b.com", "c.com"] {
            cache.store(key(name), response: [UInt8](repeating: 1, count: 10), entryTTL: 60)
        }
        XCTAssertNotNil(cache.lookup(key("a.com")), "touch a so b is least recently used")
        cache.store(key("d.com"), response: [UInt8](repeating: 1, count: 10), entryTTL: 60)

        XCTAssertEqual(cache.entryCount, 3)
        XCTAssertNil(cache.lookup(key("b.com")))
        XCTAssertNotNil(cache.lookup(key("a.com")))
        XCTAssertNotNil(cache.lookup(key("c.com")))
        XCTAssertNotNil(cache.lookup(key("d.com")))
        XCTAssertEqual(cache.counters.evictions, 1)
    }

    func testLRUEvictionByByteLimit() {
        var cache = makeCache(maxBytes: 100)
        cache.store(key("a.com"), response: [UInt8](repeating: 1, count: 40), entryTTL: 60)
        cache.store(key("b.com"), response: [UInt8](repeating: 2, count: 40), entryTTL: 60)
        XCTAssertEqual(cache.byteCount, 80)
        _ = cache.lookup(key("a.com"))
        cache.store(key("c.com"), response: [UInt8](repeating: 3, count: 40), entryTTL: 60)

        XCTAssertEqual(cache.entryCount, 2)
        XCTAssertEqual(cache.byteCount, 80)
        XCTAssertNil(cache.lookup(key("b.com")))
        XCTAssertNotNil(cache.lookup(key("a.com")))
        XCTAssertNotNil(cache.lookup(key("c.com")))
        XCTAssertEqual(cache.counters.evictions, 1)
    }

    func testByteLimitCanEvictSeveralEntries() {
        var cache = makeCache(maxBytes: 100)
        for name in ["a.com", "b.com", "c.com"] {
            cache.store(key(name), response: [UInt8](repeating: 1, count: 30), entryTTL: 60)
        }
        XCTAssertTrue(cache.store(key("big.com"), response: [UInt8](repeating: 1, count: 100), entryTTL: 60))
        XCTAssertEqual(cache.entryCount, 1)
        XCTAssertEqual(cache.byteCount, 100)
        XCTAssertEqual(cache.counters.evictions, 3)
    }

    func testResponseLargerThanByteLimitIsRejected() {
        var cache = makeCache(maxBytes: 50)
        XCTAssertFalse(cache.store(key("a.com"), response: [UInt8](repeating: 1, count: 51), entryTTL: 60))
        XCTAssertEqual(cache.entryCount, 0)
    }

    func testReplacingAKeyAdjustsByteCount() {
        var cache = makeCache()
        cache.store(key("a.com"), response: [UInt8](repeating: 1, count: 40), entryTTL: 60)
        cache.store(key("a.com"), response: [UInt8](repeating: 2, count: 25), entryTTL: 60)
        XCTAssertEqual(cache.entryCount, 1)
        XCTAssertEqual(cache.byteCount, 25)
        XCTAssertEqual(cache.lookup(key("a.com"))?.response.count, 25)
    }

    func testDefaultLimits() {
        XCTAssertEqual(DNSCache.maxEntries, 2_000)
        XCTAssertEqual(DNSCache.maxBytes, 1_048_576)
    }

    // MARK: Clear and generation

    func testClearDropsEverythingAndBumpsGeneration() throws {
        var cache = makeCache()
        XCTAssertEqual(cache.generation, 0)
        for name in ["a.com", "b.com"] {
            let q = query(name)
            cache.store(query: try parsed(q), response: Data(try makeResponse(for: q, answers: [.a(ttl: 60)])))
        }
        XCTAssertEqual(cache.entryCount, 2)

        let dropped = cache.clear(reason: .user)
        XCTAssertEqual(dropped, 2)
        XCTAssertEqual(cache.entryCount, 0)
        XCTAssertEqual(cache.byteCount, 0)
        XCTAssertEqual(cache.generation, 1)
        XCTAssertTrue(isMiss(cache.lookup(query: try parsed(query("a.com")))))

        XCTAssertEqual(cache.clear(reason: .networkChange), 0)
        XCTAssertEqual(cache.generation, 2, "clearing an empty cache still bumps the generation")
    }

    func testClearReasonLabels() {
        XCTAssertEqual(DNSCache.ClearReason.resolverChange.rawValue, "resolver change")
        XCTAssertEqual(DNSCache.ClearReason.resolverStatusChange.rawValue, "resolver status change")
        XCTAssertEqual(DNSCache.ClearReason.networkChange.rawValue, "network change")
        XCTAssertEqual(DNSCache.ClearReason.user.rawValue, "user")
        XCTAssertEqual(DNSCache.ClearReason.tunnelStop.rawValue, "tunnel stop")
    }

    func testCountersTrackHitsAndMisses() throws {
        var cache = makeCache()
        let q = query("example.com")
        XCTAssertTrue(isMiss(cache.lookup(query: try parsed(q))))
        cache.store(query: try parsed(q), response: Data(try makeResponse(for: q, answers: [.a(ttl: 60)])))
        _ = cache.lookup(query: try parsed(q))
        _ = cache.lookup(query: try parsed(q))
        XCTAssertEqual(cache.counters.hits, 2)
        XCTAssertEqual(cache.counters.misses, 1)
    }

    private func seedHitAndMiss(_ cache: inout DNSCache) throws {
        let q = query("example.com")
        _ = cache.lookup(query: try parsed(q))
        cache.store(query: try parsed(q), response: Data(try makeResponse(for: q, answers: [.a(ttl: 60)])))
        _ = cache.lookup(query: try parsed(q))
    }

    func testUserClearResetsCounters() throws {
        var cache = makeCache()
        try seedHitAndMiss(&cache)
        XCTAssertEqual(cache.counters.hits, 1)
        XCTAssertEqual(cache.counters.misses, 1)
        cache.clear(reason: .user)
        XCTAssertEqual(cache.counters.hits, 0)
        XCTAssertEqual(cache.counters.misses, 0)
    }

    func testNonUserClearKeepsCounters() throws {
        var cache = makeCache()
        try seedHitAndMiss(&cache)
        cache.clear(reason: .networkChange)
        XCTAssertEqual(cache.counters.hits, 1)
        XCTAssertEqual(cache.counters.misses, 1)
    }

    func testMaintainAfterUserClearDoesNotUnderflow() throws {
        var cache = makeCache()
        try seedHitAndMiss(&cache)
        clock.advance(DNSCache.summaryInterval + 1)
        cache.maintain() // baseline now holds the pre-clear counters
        try seedHitAndMiss(&cache)
        cache.clear(reason: .user)
        clock.advance(DNSCache.summaryInterval + 1)
        cache.maintain() // would trap on UInt64 underflow without the baseline reset
        XCTAssertEqual(cache.counters.hits, 0)
    }
}

// MARK: - Engine tests

private final class CountingUpstream: DNSUpstream, @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    private let respond: @Sendable (Data) async throws -> Data

    init(_ respond: @escaping @Sendable (Data) async throws -> Data) { self.respond = respond }

    var calls: Int { lock.withLock { names.count } }
    var queriedNames: [String] { lock.withLock { names } }

    func resolve(_ query: Data) async throws -> Data {
        let name = (try? DNSParser.parseQuery(query).questionName) ?? "?"
        lock.withLock { names.append(name) }
        return try await respond(query)
    }
}

private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var entered = 0

    func wait() async {
        entered += 1
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private func answerA(_ query: Data, ttl: UInt32 = 300, address: [UInt8] = [93, 184, 216, 34]) async throws -> Data {
    Data(try makeResponse(for: query, answers: [.a(ttl: ttl, address)]))
}

final class DNSProxyEngineCacheTests: XCTestCase {

    private var paths: AppGroupPaths!
    private var clock: TestClock!

    override func setUpWithError() throws {
        clock = TestClock()
        paths = AppGroupPaths(containerURL: try makeTempDirectory())
        try paths.ensureDirectories()
        try CompiledBlocklist.write(hashes: [FNV1a.hash64("ads.example.com")], generation: 1, to: paths.blocklistURL)
        try CompiledBlocklist.write(hashes: [], generation: 1, to: paths.userAllowlistURL)
    }

    private func makeEngine(upstream: DNSUpstream,
                            configuration: DNSProxyEngine.Configuration = .init(),
                            statsURL: URL? = nil) throws -> DNSProxyEngine {
        let clock = self.clock!
        return DNSProxyEngine(
            matcher: paths.loadMatcher(),
            upstream: upstream,
            logWriter: try QueryLogRingWriter(url: paths.queryLogURL, capacity: 1024),
            statsURL: statsURL ?? paths.statsURL,
            configuration: configuration,
            cache: DNSCache(now: { clock.now }))
    }

    private func send(_ engine: DNSProxyEngine, _ name: String, id: UInt16 = 0x1234,
                      qtype: UInt16 = DNSRecordType.a, raw: Data? = nil) async -> [Data] {
        let payload = raw ?? query(name, id: id, qtype: qtype)
        return await engine.handlePacket(makeUDPPacketV4(payload: [UInt8](payload)))
    }

    private func payload(_ replies: [Data], file: StaticString = #filePath, line: UInt = #line) throws -> [UInt8] {
        XCTAssertEqual(replies.count, 1, file: file, line: line)
        let udp = try XCTUnwrap(PacketParser.parseUDP(try XCTUnwrap(replies.first)), file: file, line: line)
        return [UInt8](udp.payload)
    }

    private func waitUntil(_ condition: () async -> Bool) async {
        for _ in 0..<300 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testSecondIdenticalQueryIsServedFromCacheWithNewIDAndCasing() async throws {
        let upstream = CountingUpstream { try await answerA($0) }
        let engine = try makeEngine(upstream: upstream)

        let first = try payload(await send(engine, "www.example.com", id: 0x1111))
        XCTAssertEqual(upstream.calls, 1)
        XCTAssertEqual(MiniDNSResponse(Data(first))?.id, 0x1111)

        let second = query("wWw.eXaMpLe.CoM", id: 0x2222)
        let reply = try payload(await send(engine, "", raw: second))
        XCTAssertEqual(upstream.calls, 1, "no second upstream call")

        let response = try XCTUnwrap(MiniDNSResponse(Data(reply)))
        XCTAssertEqual(response.id, 0x2222)
        XCTAssertTrue(response.isResponse)
        XCTAssertEqual(response.answerRData, [93, 184, 216, 34])
        let rawQuestion = try parsed(second).rawQuestion
        XCTAssertEqual(Array(reply[12..<(12 + rawQuestion.count)]), rawQuestion, "0x20 casing is echoed")
    }

    func testCachedAnswerCountsDownAndExpiresUpstreamAgain() async throws {
        let upstream = CountingUpstream { try await answerA($0, ttl: 100) }
        let engine = try makeEngine(upstream: upstream)
        _ = await send(engine, "example.com")

        clock.advance(40)
        let reply = try payload(await send(engine, "example.com", id: 9))
        XCTAssertEqual(upstream.calls, 1)
        XCTAssertEqual(try recordTTLs(reply).map(\.ttl), [60])

        clock.advance(60)
        _ = await send(engine, "example.com", id: 10)
        XCTAssertEqual(upstream.calls, 2, "expired entry goes back upstream")
    }

    func testBlockedNamesAreNeverCachedOrServedFromCache() async throws {
        let upstream = CountingUpstream { try await answerA($0) }
        let engine = try makeEngine(upstream: upstream)

        for id in 1...3 {
            let reply = try payload(await send(engine, "ads.example.com", id: UInt16(id)))
            XCTAssertEqual(MiniDNSResponse(Data(reply))?.answerRData, [0, 0, 0, 0])
        }
        XCTAssertEqual(upstream.calls, 0)
        var snapshot = await engine.statsSnapshot()
        XCTAssertEqual(snapshot.cacheEntries, 0)
        XCTAssertEqual(snapshot.cacheHits, 0)
        XCTAssertEqual(snapshot.cacheMisses, 0)

        // A name cached while allowed is blocked once the rules change.
        _ = await send(engine, "later.example.org")
        snapshot = await engine.statsSnapshot()
        XCTAssertEqual(snapshot.cacheEntries, 1)
        try CompiledBlocklist.write(hashes: [FNV1a.hash64("later.example.org")], generation: 2, to: paths.blocklistURL)
        await engine.reload(matcher: paths.loadMatcher())
        let reply = try payload(await send(engine, "later.example.org", id: 5))
        XCTAssertEqual(MiniDNSResponse(Data(reply))?.answerRData, [0, 0, 0, 0])
        XCTAssertEqual(upstream.calls, 1)
    }

    func testSetUpstreamClearsCache() async throws {
        let upstream = CountingUpstream { try await answerA($0) }
        let engine = try makeEngine(upstream: upstream)
        _ = await send(engine, "example.com")
        var snapshot = await engine.statsSnapshot()
        XCTAssertEqual(snapshot.cacheEntries, 1)

        await engine.setUpstream(upstream)
        snapshot = await engine.statsSnapshot()
        XCTAssertEqual(snapshot.cacheEntries, 0)

        _ = await send(engine, "example.com")
        XCTAssertEqual(upstream.calls, 2)
    }

    func testClearCacheReturnsDroppedCountAndForcesUpstream() async throws {
        let upstream = CountingUpstream { try await answerA($0) }
        let engine = try makeEngine(upstream: upstream)
        _ = await send(engine, "a.example.com")
        _ = await send(engine, "b.example.com")
        let dropped = await engine.clearCache(reason: .user)
        XCTAssertEqual(dropped, 2)
        _ = await send(engine, "a.example.com")
        XCTAssertEqual(upstream.calls, 3)
    }

    func testUserClearCacheResetsStatsSnapshotCounters() async throws {
        let upstream = CountingUpstream { try await answerA($0) }
        let engine = try makeEngine(upstream: upstream)
        _ = await send(engine, "example.com")
        _ = await send(engine, "example.com", id: 2)
        var snapshot = await engine.statsSnapshot()
        XCTAssertEqual(snapshot.cacheHits, 1)
        XCTAssertEqual(snapshot.cacheMisses, 1)

        _ = await engine.clearCache(reason: .user)
        snapshot = await engine.statsSnapshot()
        XCTAssertEqual(snapshot.cacheEntries, 0)
        XCTAssertEqual(snapshot.cacheHits, 0)
        XCTAssertEqual(snapshot.cacheMisses, 0)
    }

    func testLateAnswerIsNotCachedAfterClearCache() async throws {
        try await assertLateAnswerNotCached { engine, _ in _ = await engine.clearCache(reason: .networkChange) }
    }

    func testLateAnswerIsNotCachedAfterSetUpstream() async throws {
        try await assertLateAnswerNotCached { engine, upstream in await engine.setUpstream(upstream) }
    }

    private func assertLateAnswerNotCached(
        file: StaticString = #filePath, line: UInt = #line,
        interrupt: (DNSProxyEngine, DNSUpstream) async -> Void
    ) async throws {
        let gate = Gate()
        let upstream = CountingUpstream { q in
            await gate.wait()
            return try await answerA(q)
        }
        let engine = try makeEngine(upstream: upstream)

        async let inflight = send(engine, "late.example.com", id: 1)
        await waitUntil { await gate.entered == 1 }
        let entered = await gate.entered
        XCTAssertEqual(entered, 1, "upstream call should be suspended", file: file, line: line)

        await interrupt(engine, upstream)
        await gate.open()
        let reply = try payload(await inflight, file: file, line: line)
        XCTAssertEqual(MiniDNSResponse(Data(reply))?.id, 1, "the late answer is still delivered", file: file, line: line)

        let snapshot = await engine.statsSnapshot()
        XCTAssertEqual(snapshot.cacheEntries, 0, "late answer must not be stored", file: file, line: line)
        _ = await send(engine, "late.example.com", id: 2)
        XCTAssertEqual(upstream.calls, 2, "second query goes upstream", file: file, line: line)
        let after = await engine.statsSnapshot()
        XCTAssertEqual(after.cacheEntries, 1, "answers obtained after the clear are cached", file: file, line: line)
    }

    func testHitIsServedWhileInFlightIsAtLimit() async throws {
        let gate = Gate()
        let upstream = CountingUpstream { q in
            if (try? DNSParser.parseQuery(q).questionName) == "slow.example.com" { await gate.wait() }
            return try await answerA(q)
        }
        let engine = try makeEngine(upstream: upstream, configuration: .init(maxInFlight: 1))
        _ = await send(engine, "warm.example.com")

        async let slow = send(engine, "slow.example.com", id: 1)
        await waitUntil { await gate.entered == 1 }

        // A fresh miss is refused at the limit...
        let refused = try payload(await send(engine, "other.example.com", id: 2))
        XCTAssertEqual(MiniDNSResponse(Data(refused))?.rcode, 2)
        // ...but a cache hit is answered normally.
        let hit = try payload(await send(engine, "warm.example.com", id: 3))
        let response = try XCTUnwrap(MiniDNSResponse(Data(hit)))
        XCTAssertEqual(response.rcode, 0)
        XCTAssertEqual(response.id, 3)
        XCTAssertEqual(response.answerRData, [93, 184, 216, 34])

        await gate.open()
        _ = await slow
    }

    func testHitsAreRecordedAsAllowedInStatsAndQueryLog() async throws {
        let upstream = CountingUpstream { try await answerA($0) }
        let engine = try makeEngine(upstream: upstream)
        _ = await send(engine, "example.com", id: 1)
        _ = await send(engine, "example.com", id: 2)
        _ = await send(engine, "example.com", id: 3)
        await engine.flush()

        let snapshot = await engine.statsSnapshot()
        XCTAssertEqual(snapshot.totalQueries, 3)
        XCTAssertEqual(snapshot.blockedQueries, 0)

        let (records, _) = QueryLogRingReader(url: paths.queryLogURL).read(since: 0)
        XCTAssertEqual(records.count, 3)
        XCTAssertTrue(records.allSatisfy { $0.verdict == .allowed && $0.domain == "example.com" })
    }

    func testStatsSnapshotReportsCacheCounters() async throws {
        let upstream = CountingUpstream { try await answerA($0) }
        let engine = try makeEngine(upstream: upstream)

        var snapshot = await engine.statsSnapshot()
        XCTAssertEqual(snapshot.cacheEntries, 0)
        XCTAssertEqual(snapshot.cacheHits, 0)
        XCTAssertEqual(snapshot.cacheMisses, 0)

        _ = await send(engine, "a.example.com")      // miss
        _ = await send(engine, "a.example.com")      // hit
        _ = await send(engine, "a.example.com")      // hit
        _ = await send(engine, "b.example.com")      // miss
        snapshot = await engine.statsSnapshot()
        XCTAssertEqual(snapshot.cacheEntries, 2)
        XCTAssertEqual(snapshot.cacheHits, 2)
        XCTAssertEqual(snapshot.cacheMisses, 2)
    }

    func testBypassedQueriesAreNeitherCachedNorCounted() async throws {
        let upstream = CountingUpstream { try await answerA($0) }
        let engine = try makeEngine(upstream: upstream)

        var cd = [UInt8](query("example.com"))
        cd[3] |= 0x10
        var doBit = [UInt8](query("example.com", edns: true))
        doBit[doBit.count - 6 + 2] = 0x80

        for bytes in [cd, cd, doBit, doBit] {
            _ = await send(engine, "", raw: Data(bytes))
        }
        XCTAssertEqual(upstream.calls, 4)
        let snapshot = await engine.statsSnapshot()
        XCTAssertEqual(snapshot.cacheEntries, 0)
        XCTAssertEqual(snapshot.cacheHits, 0)
        XCTAssertEqual(snapshot.cacheMisses, 0)
    }

    func testUncacheableUpstreamAnswersAreForwardedButNotStored() async throws {
        let upstream = CountingUpstream { q in Data(try makeResponse(for: q, rcode: 2)) }
        let engine = try makeEngine(upstream: upstream)
        let reply = try payload(await send(engine, "fail.example.com"))
        XCTAssertEqual(MiniDNSResponse(Data(reply))?.rcode, 2)
        _ = await send(engine, "fail.example.com")
        XCTAssertEqual(upstream.calls, 2)
        let snapshot = await engine.statsSnapshot()
        XCTAssertEqual(snapshot.cacheEntries, 0)
    }

    // MARK: flush / blockTTL

    func testFlushSkipsStatsWriteWhenUnchanged() async throws {
        let statsURL = paths.statsURL
        let upstream = CountingUpstream { try await answerA($0) }
        let engine = try makeEngine(upstream: upstream, statsURL: statsURL)

        await engine.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: statsURL.path), "nothing recorded, nothing written")

        _ = await send(engine, "example.com")
        await engine.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: statsURL.path))
        XCTAssertEqual(StatsPersistence.load(from: statsURL).totalQueries, 1)

        // Unchanged counters: a deleted file is not rewritten.
        try FileManager.default.removeItem(at: statsURL)
        await engine.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: statsURL.path), "flush must skip the write")

        // A new query makes the stats dirty again.
        _ = await send(engine, "example.com", id: 2)
        await engine.flush()
        XCTAssertEqual(StatsPersistence.load(from: statsURL).totalQueries, 2)
    }

    func testBlockTTLDefaultsToTenSeconds() async throws {
        XCTAssertEqual(DNSProxyEngine.Configuration().blockTTL, 10)

        let upstream = CountingUpstream { _ in throw UpstreamError.timeout }
        let engine = try makeEngine(upstream: upstream)
        let reply = try payload(await send(engine, "ads.example.com"))
        XCTAssertEqual(try recordTTLs(reply).map(\.ttl), [10])
    }
}

// MARK: - IPC and presentation

final class DNSCacheIPCTests: XCTestCase {

    func testClearDNSCacheRequestRoundTrips() throws {
        let data = try TunnelIPCCoder.encode(.clearDNSCache)
        guard case .clearDNSCache = try TunnelIPCCoder.decodeRequest(data) else {
            return XCTFail("expected clearDNSCache")
        }
        let ok = try TunnelIPCCoder.encode(.ok)
        guard case .ok = try TunnelIPCCoder.decodeResponse(ok) else { return XCTFail("expected ok") }
    }

    func testRuntimeStatsCacheFieldsRoundTrip() throws {
        let stats = TunnelRuntimeStats(totalQueries: 10, blockedQueries: 3, blocklistEntryCount: 99,
                                       cacheEntries: 42, cacheHits: 7, cacheMisses: 5)
        let data = try TunnelIPCCoder.encode(.stats(stats))
        guard case .stats(let decoded) = try TunnelIPCCoder.decodeResponse(data) else {
            return XCTFail("expected stats")
        }
        XCTAssertEqual(decoded, stats)
        XCTAssertEqual(decoded.cacheEntries, 42)
        XCTAssertEqual(decoded.cacheHits, 7)
        XCTAssertEqual(decoded.cacheMisses, 5)
    }

    func testOldPayloadWithoutCacheFieldsStillDecodes() throws {
        let stats = TunnelRuntimeStats(totalQueries: 10, blockedQueries: 3, blocklistEntryCount: 99,
                                       cacheEntries: 42, cacheHits: 7, cacheMisses: 5)
        let encoded = try TunnelIPCCoder.encode(.stats(stats))
        let object = try JSONSerialization.jsonObject(with: encoded)
        let stripped = Self.removing(["cacheEntries", "cacheHits", "cacheMisses"], from: object)
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: stripped), as: UTF8.self)
            .contains("cacheEntries"))
        let old = try JSONSerialization.data(withJSONObject: stripped)

        guard case .stats(let decoded) = try TunnelIPCCoder.decodeResponse(old) else {
            return XCTFail("expected stats")
        }
        XCTAssertEqual(decoded.totalQueries, 10)
        XCTAssertEqual(decoded.blockedQueries, 3)
        XCTAssertEqual(decoded.blocklistEntryCount, 99)
        XCTAssertNil(decoded.cacheEntries)
        XCTAssertNil(decoded.cacheHits)
        XCTAssertNil(decoded.cacheMisses)
    }

    private static func removing(_ keys: Set<String>, from object: Any) -> Any {
        if let dict = object as? [String: Any] {
            return dict.filter { !keys.contains($0.key) }.mapValues { removing(keys, from: $0) }
        }
        if let array = object as? [Any] { return array.map { removing(keys, from: $0) } }
        return object
    }
}

final class CacheRowPresentationTests: XCTestCase {

    private func stats(entries: UInt64? = 5, hits: UInt64? = 0, misses: UInt64? = 0) -> TunnelRuntimeStats {
        TunnelRuntimeStats(cacheEntries: entries, cacheHits: hits, cacheMisses: misses)
    }

    func testNilStatsOrDisconnectedIsNotAvailable() {
        XCTAssertEqual(CacheRowPresentation(tunnelConnected: true, stats: nil).text, "Not available")
        XCTAssertEqual(CacheRowPresentation(tunnelConnected: false, stats: stats(hits: 5, misses: 5)).text,
                       "Not available")
        XCTAssertEqual(CacheRowPresentation(tunnelConnected: false, stats: nil).text, "Not available")
    }

    func testOlderTunnelWithoutCacheFieldsIsNotAvailable() {
        for s in [stats(entries: nil), stats(hits: nil), stats(misses: nil)] {
            XCTAssertEqual(CacheRowPresentation(tunnelConnected: true, stats: s).text, "Not available")
        }
    }

    func testZeroLookupsShowsNoLookupsYet() {
        XCTAssertEqual(CacheRowPresentation(tunnelConnected: true, stats: stats(entries: 0)).text,
                       "0 entries · no lookups yet")
        XCTAssertEqual(CacheRowPresentation(tunnelConnected: true, stats: stats(entries: 12)).text,
                       "12 entries · no lookups yet")
    }

    func testPercentagesRoundDown() {
        func text(_ hits: UInt64, _ misses: UInt64) -> String {
            CacheRowPresentation(tunnelConnected: true, stats: stats(entries: 3, hits: hits, misses: misses)).text
        }
        XCTAssertEqual(text(1, 2), "3 entries · 33% hit rate")
        XCTAssertEqual(text(2, 1), "3 entries · 66% hit rate")
        XCTAssertEqual(text(199, 1), "3 entries · 99% hit rate")
        XCTAssertEqual(text(1, 199), "3 entries · 0% hit rate")
        XCTAssertEqual(text(0, 4), "3 entries · 0% hit rate")
        XCTAssertEqual(text(4, 0), "3 entries · 100% hit rate")
        XCTAssertEqual(text(1, 1), "3 entries · 50% hit rate")
        XCTAssertEqual(text(29, 71), "3 entries · 29% hit rate")
    }

    func testHugeCountersDoNotTrap() {
        let s = stats(entries: 1, hits: UInt64.max, misses: UInt64.max)
        XCTAssertEqual(CacheRowPresentation(tunnelConnected: true, stats: s).text, "1 entries · 50% hit rate")
        let big = stats(entries: 1, hits: UInt64.max / 2, misses: 10)
        XCTAssertTrue(CacheRowPresentation(tunnelConnected: true, stats: big).text.hasSuffix("% hit rate"))
    }
}
