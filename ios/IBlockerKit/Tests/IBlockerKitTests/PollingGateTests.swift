import XCTest
@testable import IBlockerKit

final class PollingGateTests: XCTestCase {
    func testRegisteredWhileInactiveDoesNotRun() {
        var gate = PollingGate()
        gate.setActive(false)
        gate.register()
        XCTAssertFalse(gate.shouldRun)
    }

    func testBecomingActiveRuns() {
        var gate = PollingGate()
        gate.setActive(false)
        gate.register()
        gate.setActive(true)
        XCTAssertTrue(gate.shouldRun)
    }

    func testUnregisterToZeroWhileInactiveThenActiveDoesNotRun() {
        var gate = PollingGate()
        gate.register()
        gate.setActive(false)
        gate.unregister()
        gate.setActive(true)
        XCTAssertFalse(gate.shouldRun)
    }

    func testReferenceCountingKeepsRunningUntilLastUnregister() {
        var gate = PollingGate()
        gate.register()
        gate.register()
        gate.unregister()
        XCTAssertTrue(gate.shouldRun)
        gate.unregister()
        gate.unregister()
        XCTAssertFalse(gate.shouldRun)
        XCTAssertEqual(gate.pollers, 0)
    }
}
