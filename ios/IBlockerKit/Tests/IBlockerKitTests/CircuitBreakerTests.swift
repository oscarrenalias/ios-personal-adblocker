import XCTest
@testable import IBlockerKit

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ s: TimeInterval) { lock.withLock { current = current.addingTimeInterval(s) } }
}

final class CircuitBreakerTests: XCTestCase {
    private func make(_ clock: Clock) -> CircuitBreaker {
        CircuitBreaker(name: "Test", effect: "using network DNS", now: { clock.now })
    }

    private func trip(_ b: inout CircuitBreaker) {
        for _ in 0..<3 { b.recordFailure(generation: b.generation) }
    }

    func testThreeFailuresTrip() {
        let clock = Clock()
        var b = make(clock)
        let g = b.generation
        trip(&b)
        XCTAssertEqual(b.state, .down(nextProbeAt: clock.now.addingTimeInterval(5), backoff: 5, since: clock.now))
        XCTAssertEqual(b.generation, g + 1)
    }

    func testSuccessResetsCount() {
        var b = make(Clock())
        b.recordFailure(generation: b.generation)
        b.recordFailure(generation: b.generation)
        b.recordSuccess(generation: b.generation)
        XCTAssertEqual(b.state, .healthy(consecutiveFailures: 0))
        b.recordFailure(generation: b.generation)
        b.recordFailure(generation: b.generation)
        XCTAssertEqual(b.state, .healthy(consecutiveFailures: 2))
    }

    func testIntermittentFailuresDoNotTrip() {
        var b = make(Clock())
        b.recordFailure(generation: b.generation)
        b.recordFailure(generation: b.generation)
        b.recordSuccess(generation: b.generation)
        b.recordFailure(generation: b.generation)
        XCTAssertEqual(b.state, .healthy(consecutiveFailures: 1))
    }

    func testStaleGenerationIgnored() {
        var b = make(Clock())
        let stale = b.generation
        trip(&b)
        let state = b.state, gen = b.generation
        b.recordFailure(generation: stale)
        b.recordSuccess(generation: stale)
        b.probeSucceeded(generation: stale)
        b.probeFailed(generation: stale, error: "x")
        XCTAssertEqual(b.state, state)
        XCTAssertEqual(b.generation, gen)

        var h = make(Clock())
        h.recordFailure(generation: h.generation)
        h.recordFailure(generation: 99)
        XCTAssertEqual(h.state, .healthy(consecutiveFailures: 1))
    }

    func testIsAvailableFlipsAtNextProbeAt() {
        let clock = Clock()
        var b = make(clock)
        XCTAssertTrue(b.isAvailable)
        trip(&b)
        XCTAssertFalse(b.isAvailable)
        clock.advance(4.9)
        XCTAssertFalse(b.isAvailable)
        clock.advance(0.1)
        XCTAssertTrue(b.isAvailable)
    }

    func testBackoffSequenceAndCap() {
        let clock = Clock()
        var b = make(clock)
        trip(&b)
        var backoffs: [TimeInterval] = []
        for _ in 0..<8 {
            guard case .down(let next, let backoff, _) = b.state else { return XCTFail("not down") }
            backoffs.append(backoff)
            clock.advance(next.timeIntervalSince(clock.now))
            XCTAssertTrue(b.probeDue(clock.now))
            b.probeFailed(generation: b.generation, error: "fail")
        }
        XCTAssertEqual(backoffs, [5, 10, 20, 40, 80, 160, 300, 300])
    }

    func testProbeDueOnlyOnceAndNotBeforeNextProbeAt() {
        let clock = Clock()
        var b = make(clock)
        XCTAssertFalse(b.probeDue(clock.now))
        trip(&b)
        clock.advance(4)
        XCTAssertFalse(b.probeDue(clock.now))
        clock.advance(1)
        XCTAssertTrue(b.probeDue(clock.now))
        XCTAssertFalse(b.probeDue(clock.now))
        XCTAssertFalse(b.probeDue(clock.now))
    }

    func testProbeSuccessRestoresAndNextTripStartsAt5() {
        let clock = Clock()
        var b = make(clock)
        trip(&b)
        clock.advance(5)
        XCTAssertTrue(b.probeDue(clock.now))
        b.probeFailed(generation: b.generation, error: "x")   // backoff now 10
        clock.advance(10)
        XCTAssertTrue(b.probeDue(clock.now))
        let g = b.generation
        b.probeSucceeded(generation: g)
        XCTAssertEqual(b.state, .healthy(consecutiveFailures: 0))
        XCTAssertEqual(b.generation, g + 1)
        trip(&b)
        guard case .down(_, let backoff, _) = b.state else { return XCTFail("not down") }
        XCTAssertEqual(backoff, 5)
    }

    func testNetworkChange() {
        let clock = Clock()
        var b = make(clock)
        trip(&b)
        let g = b.generation
        b.networkChange()
        XCTAssertEqual(b.state, .healthy(consecutiveFailures: 0))
        XCTAssertEqual(b.generation, g + 1)
        XCTAssertTrue(b.probeDue(clock.now))
        XCTAssertFalse(b.probeDue(clock.now))
        b.probeFailed(generation: b.generation, error: "x")
        XCTAssertEqual(b.state, .healthy(consecutiveFailures: 1))
    }

    func testProbeResultFromBeforeNetworkChangeIsIgnored() {
        let clock = Clock()
        var b = make(clock)
        trip(&b)
        clock.advance(5)
        XCTAssertTrue(b.probeDue(clock.now))
        let old = b.generation
        b.networkChange()
        b.probeFailed(generation: old, error: "x")
        b.probeSucceeded(generation: old)
        XCTAssertEqual(b.state, .healthy(consecutiveFailures: 0))
        XCTAssertEqual(b.generation, old + 1)
    }

    func testBurstOfFailuresStartedBeforeFirstCountedCountsOnce() {
        let clock = Clock()
        var b = make(clock)
        let started = clock.now
        clock.advance(2)
        for _ in 0..<3 { b.recordFailure(generation: b.generation, startedAt: started) }
        XCTAssertEqual(b.state, .healthy(consecutiveFailures: 1))
    }

    func testSequentialFailuresTrip() {
        let clock = Clock()
        var b = make(clock)
        for _ in 0..<3 {
            let started = clock.now
            clock.advance(2)
            b.recordFailure(generation: b.generation, startedAt: started)
        }
        XCTAssertTrue(b.isDown)
    }

    func testSuccessClearsBurstWindow() {
        let clock = Clock()
        var b = make(clock)
        let started = clock.now
        clock.advance(2)
        b.recordFailure(generation: b.generation, startedAt: started)
        b.recordSuccess(generation: b.generation)
        b.recordFailure(generation: b.generation, startedAt: started)
        XCTAssertEqual(b.state, .healthy(consecutiveFailures: 1))
    }
}
