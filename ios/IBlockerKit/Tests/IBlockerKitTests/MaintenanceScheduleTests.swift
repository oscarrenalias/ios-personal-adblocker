import XCTest
@testable import IBlockerKit

final class MaintenanceScheduleTests: XCTestCase {
    private typealias S = MaintenanceSchedule
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testIdleTimerStepsAndInterval() {
        var s = S(degraded: false, now: t0)
        let p = s.plan(reason: .timer, degraded: false, now: t0)
        XCTAssertEqual(p.steps, [.flush, .settings, .blocklistCheck])
        XCTAssertEqual(p.interval, 60)
        XCTAssertEqual(p.nextWake, t0.addingTimeInterval(60))
    }

    func testDegradedTimerStepsAndInterval() {
        var s = S(degraded: true, now: t0)
        let p = s.plan(reason: .timer, degraded: true, now: t0)
        XCTAssertEqual(p.steps, [.flush, .settings, .recovery])
        XCTAssertEqual(p.interval, 2)
    }

    func testDegradedBlocklistCheckOnlyOnFifthTimerPass() {
        var s = S(degraded: true, now: t0)
        var now = t0
        for pass in 1...10 {
            now = now.addingTimeInterval(2)
            let p = s.plan(reason: .timer, degraded: true, now: now)
            XCTAssertEqual(p.steps.contains(.blocklistCheck), pass % 5 == 0, "pass \(pass)")
        }
    }

    func testSignalPassesLeaveDeadlineAndTickUnchanged() {
        var s = S(degraded: true, now: t0)
        _ = s.plan(reason: .timer, degraded: true, now: t0.addingTimeInterval(1))
        let before = s
        let settings = s.plan(reason: .settings, degraded: true, now: t0.addingTimeInterval(1.5))
        XCTAssertEqual(settings.steps, [.settings, .recovery])
        let blocklist = s.plan(reason: .blocklist, degraded: true, now: t0.addingTimeInterval(1.6))
        XCTAssertEqual(blocklist.steps, [.blocklistCheck])
        XCTAssertEqual(s, before)
    }

    func testSettingsSignalWhenIdleHasNoRecovery() {
        var s = S(degraded: false, now: t0)
        XCTAssertEqual(s.plan(reason: .settings, degraded: false, now: t0).steps, [.settings])
    }

    func testTransitionsResetTickAndDeadline() {
        var s = S(degraded: true, now: t0)
        for i in 1...3 { _ = s.plan(reason: .timer, degraded: true, now: t0.addingTimeInterval(Double(i) * 2)) }
        XCTAssertEqual(s.tick, 3)

        let later = t0.addingTimeInterval(7)
        let idle = s.plan(reason: .settings, degraded: false, now: later)
        XCTAssertEqual(s.tick, 0)
        XCTAssertEqual(s.deadline, later.addingTimeInterval(60))
        XCTAssertEqual(idle.interval, 60)

        let later2 = later.addingTimeInterval(10)
        let degraded = s.plan(reason: .blocklist, degraded: true, now: later2)
        XCTAssertEqual(s.tick, 0)
        XCTAssertEqual(s.deadline, later2.addingTimeInterval(2))
        XCTAssertEqual(degraded.interval, 2)
    }

    func testVerboseDeadlineEarlierShortensWake() {
        var s = S(degraded: false, now: t0)
        let until = t0.addingTimeInterval(10)
        let p = s.plan(reason: .timer, degraded: false, now: t0, verboseLoggingUntil: until)
        XCTAssertEqual(p.nextWake, until.addingTimeInterval(S.verboseMargin))
        XCTAssertEqual(p.interval, 11)
        // Deadline itself is not shortened.
        XCTAssertEqual(s.deadline, t0.addingTimeInterval(60))
    }

    func testVerboseDeadlinePastOrLaterIsIgnored() {
        var s = S(degraded: false, now: t0)
        let past = s.plan(reason: .timer, degraded: false, now: t0,
                          verboseLoggingUntil: t0.addingTimeInterval(-30))
        XCTAssertEqual(past.interval, 60)
        let later = s.plan(reason: .timer, degraded: false, now: t0,
                           verboseLoggingUntil: t0.addingTimeInterval(500))
        XCTAssertEqual(later.interval, 60)
    }

    func testIntervalNeverNegative() {
        var s = S(degraded: false, now: t0)
        // Signal pass long after the deadline: deadline is stale.
        let p = s.plan(reason: .settings, degraded: false, now: t0.addingTimeInterval(500))
        XCTAssertEqual(p.interval, 0)
        let p2 = s.plan(reason: .settings, degraded: false, now: t0.addingTimeInterval(500),
                        verboseLoggingUntil: t0.addingTimeInterval(520))
        XCTAssertGreaterThanOrEqual(p2.interval, 0)
        XCTAssertGreaterThanOrEqual(s.wake(now: t0.addingTimeInterval(1000), verboseLoggingUntil: nil)
            .timeIntervalSince(t0.addingTimeInterval(1000)), -1000)
    }
}
