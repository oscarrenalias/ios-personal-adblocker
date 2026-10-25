import XCTest
@testable import IBlockerKit

final class ListFreshnessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000_000)
    private let week: TimeInterval = 7 * 24 * 60 * 60

    private func stale(secondsAgo: TimeInterval) -> Bool {
        ListFreshness.isStale(lastAccepted: now.addingTimeInterval(-secondsAgo), now: now)
    }

    func testNilIsNotStale() {
        XCTAssertFalse(ListFreshness.isStale(lastAccepted: nil, now: now))
    }

    func testRecentIsFresh() {
        XCTAssertFalse(stale(secondsAgo: 0))
        XCTAssertFalse(stale(secondsAgo: 3600))
    }

    func testExactlySevenDaysIsFresh() {
        XCTAssertFalse(stale(secondsAgo: week))
    }

    func testJustOverSevenDaysIsStale() {
        XCTAssertTrue(stale(secondsAgo: week + 1))
    }

    func testFutureDateIsFresh() {
        XCTAssertFalse(stale(secondsAgo: -3600))
    }

    func testCustomThreshold() {
        XCTAssertTrue(ListFreshness.isStale(lastAccepted: now.addingTimeInterval(-61), now: now, threshold: 60))
        XCTAssertFalse(ListFreshness.isStale(lastAccepted: now.addingTimeInterval(-60), now: now, threshold: 60))
    }
}
