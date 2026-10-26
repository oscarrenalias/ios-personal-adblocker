import XCTest
@testable import IBlockerKit

final class ListExceptionsAndExplainTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = try makeTempDirectory()
    }

    private func v2(_ name: String, _ entries: [(String, UInt8)]) throws -> CompiledBlocklistView {
        let url = dir.appendingPathComponent(name)
        try writeV2Blob(entries, to: url)
        return try loadView(url)
    }

    private func v1(_ name: String, _ domains: [String]) throws -> CompiledBlocklistView {
        let url = dir.appendingPathComponent(name)
        try writeV1Blob(domains, to: url)
        return try loadView(url)
    }

    private func matcher(block: [(String, UInt8)] = [], exceptions: [(String, UInt8)]? = nil,
                         allow: [String] = [], deny: [String] = [], builtIn: [String] = []) throws -> DomainMatcher {
        DomainMatcher(
            blocklist: try v2("b.bin", block),
            userAllowlist: allow.isEmpty ? nil : try v1("a.bin", allow),
            userDenylist: deny.isEmpty ? nil : try v1("d.bin", deny),
            builtInBlockHashes: Set(builtIn.map { FNV1a.hash64($0) }),
            listAllowlist: try exceptions.map { try v2("x.bin", $0) })
    }

    // MARK: precedence

    func testExceptionAllowsNameAndSubdomainsButNotSiblings() throws {
        let m = try matcher(block: [("example.com", 1)], exceptions: [("safe.example.com", 2)])
        XCTAssertEqual(m.verdict(for: "safe.example.com"), .allow)
        XCTAssertEqual(m.verdict(for: "a.safe.example.com"), .allow)
        XCTAssertEqual(m.verdict(for: "ads.example.com"), .block)
        let m2 = try matcher(block: [("ads.example.com", 1)], exceptions: [("safe.example.com", 2)])
        XCTAssertEqual(m2.verdict(for: "ads.example.com"), .block)
    }

    func testExceptionOverridesBlocklistAtAnySuffixLevel() throws {
        // Exception at parent, block at child, and vice versa.
        let parentException = try matcher(block: [("a.b.example.com", 1)], exceptions: [("example.com", 2)])
        XCTAssertEqual(parentException.verdict(for: "a.b.example.com"), .allow)
        let childException = try matcher(block: [("example.com", 1)], exceptions: [("a.b.example.com", 2)])
        XCTAssertEqual(childException.verdict(for: "x.a.b.example.com"), .allow)
        XCTAssertEqual(childException.verdict(for: "other.example.com"), .block)
    }

    func testUserDenyAndBuiltInBeatExceptions() throws {
        let m = try matcher(block: [("example.com", 1)], exceptions: [("example.com", 2)],
                            deny: ["tracker.example.com"], builtIn: ["builtin.example.com"])
        XCTAssertEqual(m.verdict(for: "tracker.example.com"), .block)
        XCTAssertEqual(m.verdict(for: "x.builtin.example.com"), .block)
        XCTAssertEqual(m.verdict(for: "plain.example.com"), .allow)
    }

    func testUserAllowWinsOverEverything() throws {
        let m = try matcher(block: [("example.com", 1)], exceptions: [("example.com", 2)],
                            allow: ["example.com"], deny: ["example.com"], builtIn: ["example.com"])
        XCTAssertEqual(m.verdict(for: "www.example.com"), .allow)
        XCTAssertEqual(m.explain("www.example.com").decidingMatch?.source, .userAllowlist)
    }

    func testNilOrEmptyExceptionsBehaveAsBefore() throws {
        let nilEx = try matcher(block: [("example.com", 1)])
        let emptyEx = try matcher(block: [("example.com", 1)], exceptions: [])
        for m in [nilEx, emptyEx] {
            XCTAssertEqual(m.verdict(for: "a.example.com"), .block)
            XCTAssertEqual(m.verdict(for: "other.org"), .none)
        }
    }

    func testBareTLDAndSingleLabelAreNone() throws {
        let m = try matcher(block: [("com", 1)], exceptions: [("com", 2)])
        XCTAssertEqual(m.verdict(for: "com"), .none)
        XCTAssertEqual(m.verdict(for: "localhost"), .none)
        XCTAssertEqual(m.explain("com"), DomainMatcher.Explanation(verdict: .none, decidingMatch: nil))
        XCTAssertEqual(m.explain("").verdict, .none)
        XCTAssertNil(m.explain("").decidingMatch)
        XCTAssertNil(m.hit(for: "com"))
    }

    func testMatchedLabelCount() throws {
        let m = try matcher(block: [("example.com", 1), ("ads.tracker.net", 1)])
        XCTAssertEqual(m.hit(for: "example.com")?.matchedLabelCount, 2)
        XCTAssertEqual(m.hit(for: "a.b.example.com")?.matchedLabelCount, 2)
        XCTAssertEqual(m.hit(for: "ads.tracker.net")?.matchedLabelCount, 3)
        XCTAssertEqual(m.hit(for: "x.ads.tracker.net")?.matchedLabelCount, 3)
    }

    // MARK: explain

    func testExplainAtEachPrecedenceLevel() throws {
        let m = try matcher(block: [("list.org", 4)], exceptions: [("exc.org", 5)],
                            allow: ["ua.org"], deny: ["ud.org"], builtIn: ["bi.org"])
        func match(_ d: String) -> DomainMatcher.Match? { m.explain(d).decidingMatch }
        XCTAssertEqual(match("x.ua.org"), .init(source: .userAllowlist, matchedSuffix: "ua.org"))
        XCTAssertEqual(match("ud.org"), .init(source: .userDenylist, matchedSuffix: "ud.org"))
        XCTAssertEqual(match("a.bi.org"), .init(source: .builtIn, matchedSuffix: "bi.org"))
        XCTAssertEqual(match("a.b.exc.org"), .init(source: .listException(sourceNumber: 5), matchedSuffix: "exc.org"))
        XCTAssertEqual(match("a.list.org"), .init(source: .list(sourceNumber: 4), matchedSuffix: "list.org"))
        XCTAssertEqual(m.explain("a.list.org").verdict, .block)
        XCTAssertEqual(m.explain("exc.org").verdict, .allow)
        XCTAssertEqual(m.explain("nothing.net"), DomainMatcher.Explanation(verdict: .none, decidingMatch: nil))
    }

    func testListExceptionOverridesListBlockNotUserDenyOrBuiltIn() throws {
        let m = try matcher(block: [("x.org", 1)], exceptions: [("x.org", 2)],
                            deny: ["d.x.org"], builtIn: ["b.x.org"])
        XCTAssertEqual(m.explain("www.x.org").decidingMatch?.source, .listException(sourceNumber: 2))
        XCTAssertEqual(m.explain("d.x.org").decidingMatch?.source, .userDenylist)
        XCTAssertEqual(m.explain("b.x.org").decidingMatch?.source, .builtIn)
    }

    func testV1BlobsReportSourceNumberZero() throws {
        let url = dir.appendingPathComponent("old.bin")
        try writeV1Blob(["old.org"], to: url)
        let exURL = dir.appendingPathComponent("oldx.bin")
        try writeV1Blob(["exc.old.org"], to: exURL)
        let m = DomainMatcher(blocklist: try loadView(url), listAllowlist: try loadView(exURL))
        XCTAssertEqual(m.explain("a.old.org").decidingMatch?.source, .list(sourceNumber: 0))
        XCTAssertEqual(m.explain("exc.old.org").decidingMatch?.source, .listException(sourceNumber: 0))
    }

    func testExplainVerdictEqualsVerdictForRandomInputs() throws {
        let m = try matcher(block: [("a.com", 1), ("b.a.net", 2), ("c.org", 3)],
                            exceptions: [("x.a.com", 4), ("c.org", 5)],
                            allow: ["ok.c.org"], deny: ["deny.b.a.net"], builtIn: ["bi.io"])
        var rng = SeededGenerator(seed: 42)
        let labels = ["a", "b", "c", "x", "ok", "deny", "bi", "com", "net", "org", "io", "zz"]
        for _ in 0..<2000 {
            let count = Int.random(in: 1...5, using: &rng)
            let name = (0..<count).map { _ in labels.randomElement(using: &rng)! }.joined(separator: ".")
            let e = m.explain(name)
            XCTAssertEqual(e.verdict, m.verdict(for: name), name)
            XCTAssertEqual(e.decidingMatch == nil, e.verdict == .none, name)
            if let first = m.allMatches(for: name).first {
                XCTAssertEqual(first, e.decidingMatch, name)
            }
        }
    }

    // MARK: allMatches

    func testAllMatchesPrecedenceOrderAndSuffixOrder() throws {
        let m = try matcher(block: [("example.com", 1), ("ads.example.com", 1)],
                            exceptions: [("example.com", 2)],
                            allow: ["example.com"], deny: ["ads.example.com"], builtIn: ["example.com"])
        let all = m.allMatches(for: "x.ads.example.com")
        XCTAssertEqual(all, [
            .init(source: .userAllowlist, matchedSuffix: "example.com"),
            .init(source: .userDenylist, matchedSuffix: "ads.example.com"),
            .init(source: .builtIn, matchedSuffix: "example.com"),
            .init(source: .listException(sourceNumber: 2), matchedSuffix: "example.com"),
            .init(source: .list(sourceNumber: 1), matchedSuffix: "ads.example.com"),
            .init(source: .list(sourceNumber: 1), matchedSuffix: "example.com"),
        ])
    }

    func testAllMatchesEmptyWhenNoMatch() throws {
        let m = try matcher(block: [("example.com", 1)])
        XCTAssertEqual(m.allMatches(for: "other.org"), [])
        XCTAssertEqual(m.allMatches(for: "com"), [])
        XCTAssertEqual(DomainMatcher.empty.allMatches(for: "a.b.c"), [])
    }

    // MARK: loading

    func testLoadMatcherWithoutListAllowBlobHasNilExceptions() throws {
        let paths = AppGroupPaths(containerURL: dir)
        try paths.ensureDirectories()
        try writeV2Blob([("a.org", 1)], to: paths.blocklistURL)
        let (matcher, failures) = paths.loadMatcherReportingFailures()
        XCTAssertNil(matcher.listAllowlist)
        XCTAssertTrue(failures.isEmpty)
    }

    func testCorruptListAllowBlobReportsOneFailure() throws {
        let paths = AppGroupPaths(containerURL: dir)
        try paths.ensureDirectories()
        try writeV2Blob([("a.org", 1)], to: paths.blocklistURL)
        try Data([1, 2, 3]).write(to: paths.listAllowlistURL)
        let (matcher, failures) = paths.loadMatcherReportingFailures()
        XCTAssertNil(matcher.listAllowlist)
        XCTAssertEqual(failures.map(\.fileName), ["listallow.bin"])
    }

    func testValidListAllowBlobLoads() throws {
        let paths = AppGroupPaths(containerURL: dir)
        try paths.ensureDirectories()
        try writeV2Blob([("a.org", 1)], to: paths.blocklistURL)
        try writeV2Blob([("ok.a.org", 1)], to: paths.listAllowlistURL)
        let matcher = paths.loadMatcher()
        XCTAssertEqual(matcher.listAllowlist?.count, 1)
        XCTAssertEqual(matcher.verdict(for: "ok.a.org"), .allow)
    }

    func testRelaxBlobProtectionCoversListAllow() throws {
        let paths = AppGroupPaths(containerURL: dir)
        try paths.ensureDirectories()
        try writeV2Blob([], to: paths.listAllowlistURL)
        // Passing means the file was visited without failures.
        XCTAssertTrue(paths.relaxBlobProtection().filter { $0.fileName == "listallow.bin" }.isEmpty)
    }
}
