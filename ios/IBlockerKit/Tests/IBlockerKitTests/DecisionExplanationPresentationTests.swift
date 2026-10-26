import XCTest
@testable import IBlockerKit

final class DecisionExplanationPresentationTests: XCTestCase {

    private func state() -> FilterListState {
        var s = FilterListState(sources: [
            FilterListSource(id: "oisd", name: "OISD Big", url: URL(string: "https://x.invalid/o")!, enabled: true, isBuiltIn: true),
            FilterListSource(id: SeedRules.sourceID, name: "Core", url: URL(string: "https://x.invalid/c")!, enabled: true, isBuiltIn: true),
        ])
        s.sourceNumbers = ["oisd": 1, SeedRules.sourceID: 2, "gone": 3]
        return s
    }

    private func record(_ verdict: LogVerdict, source: UInt8, number: UInt8 = 0, labels: UInt8 = 0,
                        cache: Bool = false, route: LogRoute = .network,
                        domain: String = "a.ads.example.com") -> QueryLogRecord {
        QueryLogRecord(timestampMillis: 1, qtype: 1, verdict: verdict, listId: source, domain: domain,
                       details: QueryLogDetails(cacheHit: cache, route: route, sourceNumber: number, matchedLabels: labels))
    }

    private func why(_ r: QueryLogRecord) -> String { DecisionExplanationPresentation(record: r, state: state()).why }

    func testBlockedWording() {
        XCTAssertEqual(why(record(.blocked, source: 6, number: 1, labels: 3)), "Blocked by ads.example.com in OISD Big")
        XCTAssertEqual(why(record(.blocked, source: 3)), "Blocked by your denylist")
        XCTAssertEqual(why(record(.blocked, source: 4)), "Blocked by built-in rules")
        XCTAssertEqual(why(record(.blocked, source: 6, number: 2, labels: 2)), "Blocked by built-in rules")
    }

    func testAllowedWording() {
        XCTAssertEqual(why(record(.allowed, source: 2)), "Allowed by your allowlist")
        XCTAssertEqual(why(record(.allowed, source: 5, number: 1, labels: 2)),
                       "Allowed by example.com (exception in OISD Big)")
        XCTAssertEqual(why(record(.allowed, source: 1)), "No rule matched")
        XCTAssertEqual(why(record(.allowed, source: 7)), "Allowed: blocking was paused")
    }

    func testFailedWithRouteLine() {
        let p = DecisionExplanationPresentation(record: record(.failed, source: 1, route: .fallback), state: state())
        XCTAssertEqual(p.why, "Lookup failed")
        XCTAssertEqual(p.routeLine, "Network DNS (encrypted resolver unavailable)")
    }

    func testRecordWithoutDetails() {
        let r = QueryLogRecord(timestampMillis: 1, qtype: 1, verdict: .blocked, domain: "a.example.com")
        let p = DecisionExplanationPresentation(record: r, state: state())
        XCTAssertEqual(p.why, DecisionExplanationPresentation.notRecordedText)
        XCTAssertNil(p.routeLine)
    }

    func testSourceNumberAbsentOrZero() {
        XCTAssertEqual(why(record(.blocked, source: 6, number: 9, labels: 2)), "Blocked by example.com in a removed list")
        XCTAssertEqual(why(record(.blocked, source: 6, number: 3, labels: 2)), "Blocked by example.com in a removed list")
        XCTAssertEqual(why(record(.blocked, source: 6, number: 0, labels: 2)), "Blocked by example.com in an unknown list")
    }

    func testMatchedLabelsZeroAndLongerThanDomain() {
        XCTAssertEqual(why(record(.blocked, source: 6, number: 1, labels: 0)), "Blocked by OISD Big")
        XCTAssertEqual(why(record(.blocked, source: 6, number: 1, labels: 9, domain: "x.example.com")),
                       "Blocked by x.example.com in OISD Big")
    }

    func testRouteLines() {
        func line(_ cache: Bool, _ route: LogRoute) -> String? {
            DecisionExplanationPresentation(record: record(.allowed, source: 1, cache: cache, route: route), state: state()).routeLine
        }
        XCTAssertEqual(line(true, .fallback), "Answered from cache")
        XCTAssertEqual(line(false, .alternative), "Encrypted DNS")
        XCTAssertEqual(line(false, .network), "Network DNS")
        XCTAssertEqual(line(false, .networkOnlyName), "Network DNS (name always sent to your network)")
        XCTAssertEqual(line(false, .fallback), "Network DNS (encrypted resolver unavailable)")
        XCTAssertEqual(line(false, .local), "Answered locally (.local name)")
    }

    func testExplanationInputForEverySource() {
        func why(_ source: DomainMatcher.MatchSource?, suffix: String = "example.com") -> String {
            let match = source.map { DomainMatcher.Match(source: $0, matchedSuffix: suffix) }
            let verdict: Verdict = match == nil ? .none : .block
            let e = DomainMatcher.Explanation(verdict: verdict, decidingMatch: match)
            let p = DecisionExplanationPresentation(explanation: e, state: state())
            XCTAssertNil(p.routeLine)
            return p.why
        }
        XCTAssertEqual(why(.userAllowlist), "Allowed by your allowlist")
        XCTAssertEqual(why(.userDenylist), "Blocked by your denylist")
        XCTAssertEqual(why(.builtIn), "Blocked by built-in rules")
        XCTAssertEqual(why(.listException(sourceNumber: 1)), "Allowed by example.com (exception in OISD Big)")
        XCTAssertEqual(why(.listException(sourceNumber: 2)), "Allowed by example.com (exception in built-in rules)")
        XCTAssertEqual(why(.list(sourceNumber: 1)), "Blocked by example.com in OISD Big")
        XCTAssertEqual(why(.list(sourceNumber: 2)), "Blocked by built-in rules")
        XCTAssertEqual(why(.list(sourceNumber: 0)), "Blocked by example.com in an unknown list")
        XCTAssertEqual(why(nil), "No rule matched")
    }

    // MARK: matchLines

    func testMatchLinesFoldBundledAndDedupe() {
        let all: [DomainMatcher.Match] = [
            .init(source: .builtIn, matchedSuffix: "example.com"),
            .init(source: .list(sourceNumber: 2), matchedSuffix: "example.com"),   // bundled → folds into built-in
            .init(source: .list(sourceNumber: 1), matchedSuffix: "example.com"),
        ]
        let lines = DecisionExplanationPresentation.matchLines(deciding: all[0], all: all, state: state())
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].text, "example.com in built-in rules")
        XCTAssertTrue(lines[0].isDeciding)
        XCTAssertFalse(lines[0].isOverridden)
        XCTAssertEqual(lines[1].text, "also example.com listed in OISD Big (overridden by built-in rules)")
        XCTAssertTrue(lines[1].isOverridden)
        XCTAssertFalse(lines[1].isDeciding)
    }

    func testMatchLinesExceptionOverriddenByAllowlist() {
        let all: [DomainMatcher.Match] = [
            .init(source: .userAllowlist, matchedSuffix: "example.com"),
            .init(source: .listException(sourceNumber: 1), matchedSuffix: "example.com"),
            .init(source: .list(sourceNumber: 1), matchedSuffix: "ads.example.com"),
        ]
        let lines = DecisionExplanationPresentation.matchLines(deciding: all[0], all: all, state: state())
        XCTAssertEqual(lines.map(\.isDeciding), [true, false, false])
        XCTAssertEqual(lines[1].text,
                       "also example.com listed as an exception in OISD Big (overridden by your allowlist)")
        XCTAssertEqual(lines[2].text, "also ads.example.com listed in OISD Big (overridden by your allowlist)")
    }

    func testMatchLinesEmptyAndNoDeciding() {
        XCTAssertEqual(DecisionExplanationPresentation.matchLines(deciding: nil, all: [], state: state()), [])
        let all = [DomainMatcher.Match(source: .list(sourceNumber: 1), matchedSuffix: "a.com")]
        let lines = DecisionExplanationPresentation.matchLines(deciding: nil, all: all, state: state())
        XCTAssertEqual(lines.count, 1)
        XCTAssertFalse(lines[0].isDeciding)
    }
}
