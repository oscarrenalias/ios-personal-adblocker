import XCTest
@testable import IBlockerKit

final class TunnelSignalTests: XCTestCase {
    private let queue = DispatchQueue(label: "TunnelSignalTests")

    func testObserverReceivesPost() throws {
        let exp = expectation(description: "received")
        exp.assertForOverFulfill = false
        let observer = try TunnelSignal.observe(.settingsChanged, queue: queue) { exp.fulfill() }
        TunnelSignal.post(.settingsChanged)
        wait(for: [exp], timeout: 5)
        observer.cancel()
    }

    func testObserverIgnoresOtherSignal() throws {
        let exp = expectation(description: "not received")
        exp.isInverted = true
        let observer = try TunnelSignal.observe(.settingsChanged, queue: queue) { exp.fulfill() }
        TunnelSignal.post(.blocklistChanged)
        wait(for: [exp], timeout: 0.5)
        observer.cancel()
    }

    func testCancelledObserverReceivesNothingAndCancelIsIdempotent() throws {
        let exp = expectation(description: "not received")
        exp.isInverted = true
        let observer = try TunnelSignal.observe(.blocklistChanged, queue: queue) { exp.fulfill() }
        observer.cancel()
        observer.cancel()
        TunnelSignal.post(.blocklistChanged)
        wait(for: [exp], timeout: 0.5)
    }

    func testReleasedObserverReceivesNothing() throws {
        let exp = expectation(description: "not received")
        exp.isInverted = true
        var observer: TunnelSignal.Observer? = try TunnelSignal.observe(.blocklistChanged, queue: queue) { exp.fulfill() }
        observer = nil
        _ = observer
        TunnelSignal.post(.blocklistChanged)
        wait(for: [exp], timeout: 0.5)
    }

    func testTwoObserversOnSameSignalBothFire() throws {
        let a = expectation(description: "a")
        let b = expectation(description: "b")
        a.assertForOverFulfill = false
        b.assertForOverFulfill = false
        let o1 = try TunnelSignal.observe(.settingsChanged, queue: queue) { a.fulfill() }
        let o2 = try TunnelSignal.observe(.settingsChanged, queue: queue) { b.fulfill() }
        TunnelSignal.post(.settingsChanged)
        wait(for: [a, b], timeout: 5)
        o1.cancel(); o2.cancel()
    }
}
