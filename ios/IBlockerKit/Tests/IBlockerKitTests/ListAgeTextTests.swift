import XCTest
@testable import IBlockerKit

final class ListAgeTextTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000_000)

    private func text(secondsAgo: TimeInterval) -> String {
        ListAgeText.updated(since: now.addingTimeInterval(-secondsAgo), now: now)
    }

    func testJustNow() {
        XCTAssertEqual(text(secondsAgo: 0), "updated just now")
        XCTAssertEqual(text(secondsAgo: 59), "updated just now")
        XCTAssertEqual(text(secondsAgo: 59.9), "updated just now")
    }

    func testMinutes() {
        XCTAssertEqual(text(secondsAgo: 60), "updated 1 min ago")
        XCTAssertEqual(text(secondsAgo: 119), "updated 1 min ago")
        XCTAssertEqual(text(secondsAgo: 3599), "updated 59 min ago")
    }

    func testHours() {
        XCTAssertEqual(text(secondsAgo: 3600), "updated 1 h ago")
        XCTAssertEqual(text(secondsAgo: 86399), "updated 23 h ago")
    }

    func testDays() {
        XCTAssertEqual(text(secondsAgo: 86400), "updated 1 day ago")
        XCTAssertEqual(text(secondsAgo: 3 * 86400), "updated 3 days ago")
    }

    func testNegativeIntervalClampsToJustNow() {
        XCTAssertEqual(text(secondsAgo: -120), "updated just now")
    }
}
