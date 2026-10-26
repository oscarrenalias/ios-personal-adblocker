import XCTest
@testable import IBlockerKit

final class WidgetReloadGateTests: XCTestCase {

    func testFirstPublishReloads() {
        let d = WidgetReloadGate.evaluate(last: nil, status: .alternative(name: "A", encrypted: true))
        XCTAssertTrue(d.shouldReload)
        XCTAssertEqual(d.published, .init(state: .encrypted, name: "A"))
    }

    func testSameStateAndNameDoesNotReload() {
        let status = ResolverStatus.alternative(name: "A", encrypted: true)
        let first = WidgetReloadGate.evaluate(last: nil, status: status)
        let second = WidgetReloadGate.evaluate(last: first.published, status: status)
        XCTAssertFalse(second.shouldReload)
        XCTAssertEqual(second.published, first.published)
    }

    func testNameChangeReloads() {
        let a = WidgetReloadGate.evaluate(last: nil, status: .alternative(name: "A", encrypted: true))
        let b = WidgetReloadGate.evaluate(last: a.published, status: .alternative(name: "B", encrypted: true))
        XCTAssertTrue(b.shouldReload)
        XCTAssertEqual(b.published, .init(state: .encrypted, name: "B"))
    }

    func testStateChangeReloads() {
        let start = WidgetReloadGate.evaluate(last: nil, status: .alternative(name: "A", encrypted: true))
        let changes: [ResolverStatus] = [
            .alternative(name: "A", encrypted: false), .fallingBack(name: "A"), .failing(name: "A"), .network,
        ]
        for status in changes {
            XCTAssertTrue(WidgetReloadGate.evaluate(last: start.published, status: status).shouldReload,
                          "\(status)")
        }
    }

    func testNilLastReloadsAfterStopReset() {
        let status = ResolverStatus.network
        let first = WidgetReloadGate.evaluate(last: nil, status: status)
        XCTAssertFalse(WidgetReloadGate.evaluate(last: first.published, status: status).shouldReload)
        XCTAssertTrue(WidgetReloadGate.evaluate(last: nil, status: status).shouldReload)
    }

    func testNilStatusIsUnknownWithNilName() {
        let d = WidgetReloadGate.evaluate(last: nil, status: nil)
        XCTAssertEqual(d.published, .init(state: .unknown, name: nil))
        XCTAssertTrue(d.shouldReload)
        XCTAssertFalse(WidgetReloadGate.evaluate(last: d.published, status: nil).shouldReload)
    }
}
