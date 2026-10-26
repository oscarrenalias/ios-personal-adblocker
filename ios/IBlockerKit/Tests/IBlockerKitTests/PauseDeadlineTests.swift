import XCTest
@testable import IBlockerKit

final class PauseDeadlineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func resolve(_ minutes: Int, active: Bool = true, current: Date? = nil) -> PauseDeadline.Result {
        PauseDeadline.resolve(durationMinutes: minutes, now: now, protectionActive: active, currentPausedUntil: current)
    }

    func testDeadlineIsNowPlusDuration() {
        for minutes in [5, 10, 30, 60] {
            XCTAssertEqual(resolve(minutes),
                           .pause(deadline: now.addingTimeInterval(Double(minutes) * 60), replacedExisting: false))
        }
    }

    func testProtectionOffIsNoop() {
        XCTAssertEqual(resolve(5, active: false), .noop)
        XCTAssertNil(resolve(5, active: false).deadline)
        XCTAssertEqual(resolve(5, active: false, current: now.addingTimeInterval(600)), .noop)
    }

    func testReplacesExistingLongerPauseWithShorter() {
        let r = resolve(5, current: now.addingTimeInterval(60 * 60))
        XCTAssertEqual(r, .pause(deadline: now.addingTimeInterval(300), replacedExisting: true))
    }

    func testReplacesExistingShorterPauseWithLonger() {
        let r = resolve(60, current: now.addingTimeInterval(5 * 60))
        XCTAssertEqual(r, .pause(deadline: now.addingTimeInterval(3600), replacedExisting: true))
    }

    func testExpiredPauseIsNotReplacement() {
        XCTAssertEqual(resolve(10, current: now.addingTimeInterval(-1)).deadline, now.addingTimeInterval(600))
        guard case let .pause(_, replaced) = resolve(10, current: now.addingTimeInterval(-1)) else { return XCTFail() }
        XCTAssertFalse(replaced)
    }

    func testPausedUntilEqualToNowIsNotReplacement() {
        guard case let .pause(_, replaced) = resolve(10, current: now) else { return XCTFail() }
        XCTAssertFalse(replaced)
    }
}
