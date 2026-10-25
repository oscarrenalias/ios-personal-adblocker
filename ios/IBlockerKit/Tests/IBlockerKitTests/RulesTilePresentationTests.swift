import XCTest
@testable import IBlockerKit

final class RulesTilePresentationTests: XCTestCase {
    func testNilLiveStatsIsUnavailableNeverFileCount() {
        let p = RulesTilePresentation(liveCount: nil, compiledCount: 233_817)
        XCTAssertEqual(p, .unavailable)
        XCTAssertNil(p.value)
        XCTAssertEqual(p.caption, "Tunnel not reachable")
    }

    func testLiveLowerThanCompiledShowsLoadedOf() {
        let p = RulesTilePresentation(liveCount: 17, compiledCount: 233_817)
        XCTAssertEqual(p.value, 17)
        XCTAssertEqual(p.caption, "17 loaded of \(UInt64(233_817).formatted(.number.grouping(.automatic)))")
    }

    func testLiveMatchingCompiledHasNoCaption() {
        let p = RulesTilePresentation(liveCount: 100, compiledCount: 100)
        XCTAssertEqual(p.value, 100)
        XCTAssertNil(p.caption)
    }

    func testLiveZeroIsReportedAsLive() {
        let p = RulesTilePresentation(liveCount: 0, compiledCount: 0)
        XCTAssertEqual(p.value, 0)
    }
}
