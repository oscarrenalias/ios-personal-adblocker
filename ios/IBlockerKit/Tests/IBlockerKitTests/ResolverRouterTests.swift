import XCTest
@testable import IBlockerKit

private final class Mock: DNSUpstream, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private var _queries: [Data] = []
    var handler: @Sendable (Data) async throws -> Data
    init(_ handler: @escaping @Sendable (Data) async throws -> Data) { self.handler = handler }
    var calls: Int { lock.withLock { _calls } }
    private var _resets: [String] = []
    var resets: [String] { lock.withLock { _resets } }
    func resetConnection(reason: String) { lock.withLock { _resets.append(reason) } }
    func resolve(_ query: Data) async throws -> Data {
        lock.withLock { _calls += 1 }
        return try await handler(query)
    }
}

private func answer(_ q: Data, rcode: UInt8 = 0) -> Data {
    var b = [UInt8](q)
    guard b.count >= 4 else { return q }
    b[2] |= 0x80; b[3] = (b[3] & 0xF0) | rcode; return Data(b)
}
private func ok() -> Mock { Mock { answer($0) } }
private func failing() -> Mock { Mock { _ in throw UpstreamError.timeout } }
private func q(_ name: String, qtype: UInt16 = DNSRecordType.a) -> Data {
    makeDNSQueryData(name: name, qtype: qtype)
}
private func rcode(_ d: Data) -> UInt8 { d[3] & 0x0F }

final class ResolverRouterTests: XCTestCase {

    private func router(network: Mock, alt: Mock?, policy: FallbackPolicy = .networkDNS,
                        breaker: CircuitBreaker? = nil) -> ResolverRouter {
        ResolverRouter(network: network, alternative: alt.map { ($0, "Alt", true) },
                       policy: policy, breaker: breaker)
    }

    func testLocalNXDOMAINRegardlessOfAlternative() async throws {
        for useAlt in [false, true] {
            let net = failing(), alt = failing()
            let r = router(network: net, alt: useAlt ? alt : nil)
            for name in ["printer.local", "local", "PrInTeR.LoCaL"] {
                let resp = try await r.resolve(q(name))
                XCTAssertEqual(rcode(resp), 3, name)
            }
            let soa = try await r.resolve(q("local", qtype: 6))
            XCTAssertEqual(rcode(soa), 3)
            XCTAssertEqual(net.calls, 0)
            XCTAssertEqual(alt.calls, 0)
        }
    }

    func testAlternativeOffGoesToNetworkOnly() async throws {
        let net = ok(), alt = ok()
        let r = router(network: net, alt: nil)
        _ = try await r.resolve(q("example.com"))
        XCTAssertEqual(net.calls, 1)
        XCTAssertEqual(alt.calls, 0)
        XCTAssertEqual(r.status, .network)
    }

    func testNetworkOnlyNamesGoToNetworkUnderBothPolicies() async throws {
        for policy in [FallbackPolicy.networkDNS, .none] {
            let net = ok(), alt = ok()
            let r = router(network: net, alt: alt, policy: policy)
            _ = try await r.resolve(q("fritz.box"))
            _ = try await r.resolve(q("x.home.arpa"))
            XCTAssertEqual(net.calls, 2)
            XCTAssertEqual(alt.calls, 0)
        }
    }

    func testHealthyAlternativeAnswers() async throws {
        let net = ok(), alt = ok()
        let r = router(network: net, alt: alt)
        _ = try await r.resolve(q("example.com"))
        XCTAssertEqual(alt.calls, 1)
        XCTAssertEqual(net.calls, 0)
        XCTAssertEqual(r.status, .alternative(name: "Alt", encrypted: true))
    }

    func testAlternativeThrowsFallsBackToNetwork() async throws {
        let net = ok(), alt = failing()
        let r = router(network: net, alt: alt)
        let resp = try await r.resolve(q("example.com"))
        XCTAssertEqual(rcode(resp), 0)
        XCTAssertEqual(net.calls, 1)
    }

    func testAlternativeTimeoutFallsBackToNetwork() async throws {
        let net = ok()
        let alt = Mock { _ in try await Task.sleep(nanoseconds: 10_000_000_000); return Data() }
        let r = router(network: net, alt: alt)
        let start = Date()
        _ = try await r.resolve(q("example.com"))
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(elapsed, 1.9)
        XCTAssertLessThan(elapsed, 4)
        XCTAssertEqual(net.calls, 1)
    }

    /// An upstream that ignores task cancellation, like UDPUpstream's continuation.
    private func stubborn() -> Mock {
        Mock { q in
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { c.resume() }
            }
            return answer(q)
        }
    }

    func testNonCooperativeAlternativeTimesOutAtDeadlineAndRecordsFailure() async throws {
        let net = ok(), alt = stubborn()
        let r = router(network: net, alt: alt,
                       breaker: CircuitBreaker(name: "Alt", effect: "x", failureThreshold: 1))
        let start = Date()
        let resp = try await r.resolve(q("example.com"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertEqual(rcode(resp), 0)
        XCTAssertEqual(net.calls, 1)
        XCTAssertEqual(r.status, .fallingBack(name: "Alt"))
    }

    func testNonCooperativeAlternativePolicyNoneThrowsPromptly() async {
        let r = router(network: ok(), alt: stubborn(), policy: .none)
        let start = Date()
        do { _ = try await r.resolve(q("example.com")); XCTFail("expected throw") } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testThreeFailuresTripThenNetworkWithoutAlternative() async throws {
        let net = ok(), alt = failing()
        let r = router(network: net, alt: alt, breaker: CircuitBreaker(name: "Alt", effect: "x"))
        for _ in 0..<3 { _ = try await r.resolve(q("example.com")) }
        XCTAssertEqual(alt.calls, 3)
        XCTAssertEqual(r.status, .fallingBack(name: "Alt"))
        _ = try await r.resolve(q("example.com"))
        XCTAssertEqual(alt.calls, 3)
        XCTAssertEqual(net.calls, 4)
    }

    func testPolicyNoneThrowsAndNeverCallsNetwork() async throws {
        let net = ok(), alt = failing()
        let r = router(network: net, alt: alt, policy: .none)
        for _ in 0..<5 {
            do { _ = try await r.resolve(q("example.com")); XCTFail("expected throw") } catch {}
        }
        XCTAssertEqual(net.calls, 0)
        XCTAssertEqual(r.status, .failing(name: "Alt"))
    }

    func testBothFailThrows() async {
        let r = router(network: failing(), alt: failing())
        do { _ = try await r.resolve(q("example.com")); XCTFail("expected throw") } catch {}
    }

    func testSuccessResetsFailureCount() async throws {
        let flaky = FlakyScript([false, false, true, false, false])
        let alt = Mock { q in
            if flaky.next() { return answer(q) }
            throw UpstreamError.timeout
        }
        let r = router(network: ok(), alt: alt)
        for _ in 0..<5 { _ = try await r.resolve(q("example.com")) }
        XCTAssertEqual(alt.calls, 5)
        XCTAssertEqual(r.status, .alternative(name: "Alt", encrypted: true))
    }

    func testUnparseableDataRouting() async throws {
        let garbage = Data([1, 2, 3])
        // healthy alternative
        var net = ok(), alt = ok()
        var r = router(network: net, alt: alt)
        _ = try await r.resolve(garbage)
        XCTAssertEqual(alt.calls, 1)
        XCTAssertEqual(net.calls, 0)
        // failing alternative, networkDNS
        net = ok(); alt = failing()
        r = router(network: net, alt: alt)
        _ = try await r.resolve(garbage)
        XCTAssertEqual(net.calls, 1)
        // failing alternative, none
        net = ok(); alt = failing()
        r = router(network: net, alt: alt, policy: .none)
        do { _ = try await r.resolve(garbage); XCTFail("expected throw") } catch {}
        XCTAssertEqual(net.calls, 0)
        // alternative off
        net = ok()
        r = router(network: net, alt: nil)
        _ = try await r.resolve(garbage)
        XCTAssertEqual(net.calls, 1)
    }

    // MARK: connection stalls

    private func stalled() -> Mock {
        Mock { _ in try await Task.sleep(nanoseconds: 30_000_000_000); return Data() }
    }

    /// Device scenario: queries in flight on one stalled connection time out together.
    func testConcurrentStalledQueriesResetOnceAndDoNotTrip() async throws {
        let net = ok(), alt = stalled()
        let r = router(network: net, alt: alt)
        await withTaskGroup(of: Void.self) { g in
            for i in 0..<4 { g.addTask { _ = try? await r.resolve(q("a\(i).example.com")) } }
        }
        XCTAssertEqual(alt.resets, ["timeout"])
        XCTAssertEqual(r.status, .alternative(name: "Alt", encrypted: true))
        XCTAssertEqual(net.calls, 4)
    }

    func testSequentialTimeoutsTripAndReset() async throws {
        let net = ok(), alt = stalled()
        let r = router(network: net, alt: alt)
        for _ in 0..<3 { _ = try await r.resolve(q("example.com")) }
        XCTAssertEqual(r.status, .fallingBack(name: "Alt"))
        XCTAssertEqual(alt.resets.first, "timeout")
        XCTAssertGreaterThanOrEqual(alt.resets.count, 3)
    }

    func testSuccessAfterResetKeepsHealthy() async throws {
        let stall = FlagBox(true)
        let alt = Mock { q in
            if stall.value { try await Task.sleep(nanoseconds: 30_000_000_000) }
            return answer(q)
        }
        let r = router(network: ok(), alt: alt)
        _ = try await r.resolve(q("example.com"))
        XCTAssertEqual(alt.resets, ["timeout"])
        stall.value = false
        _ = try await r.resolve(q("example.com"))
        XCTAssertEqual(r.status, .alternative(name: "Alt", encrypted: true))
    }

    // MARK: probes (real clock, short backoff)

    private func shortBreaker(backoff: TimeInterval = 0.2) -> CircuitBreaker {
        CircuitBreaker(name: "Alt", effect: "x", backoff: backoff)
    }

    private func eventually(_ timeout: TimeInterval = 3, _ cond: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end, !cond() { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    func testProbeNotStartedBeforeNextProbeAt() async throws {
        let net = ok(), alt = failing()
        let r = router(network: net, alt: alt, breaker: CircuitBreaker(name: "Alt", effect: "x"))
        for _ in 0..<3 { _ = try await r.resolve(q("example.com")) }
        for _ in 0..<3 { _ = try await r.resolve(q("example.com")) }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(alt.calls, 3)
    }

    func testSingleProbeThenRecovery() async throws {
        let healthy = FlagBox(false)
        let alt = Mock { q in
            if healthy.value {
                try await Task.sleep(nanoseconds: 200_000_000)
                return answer(q)
            }
            throw UpstreamError.timeout
        }
        let net = ok()
        let r = router(network: net, alt: alt, breaker: shortBreaker())
        for _ in 0..<3 { _ = try await r.resolve(q("example.com")) }
        XCTAssertEqual(r.status, .fallingBack(name: "Alt"))
        healthy.value = true
        try await Task.sleep(nanoseconds: 300_000_000)
        // concurrent queries while down: exactly one probe starts
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<5 { g.addTask { _ = try? await r.resolve(q("example.com")) } }
        }
        await eventually { alt.calls >= 4 && r.status == .alternative(name: "Alt", encrypted: true) }
        XCTAssertEqual(alt.calls, 4)
        XCTAssertEqual(r.status, .alternative(name: "Alt", encrypted: true))
        _ = try await r.resolve(q("example.com"))
        XCTAssertEqual(alt.calls, 5)
    }

    func testFailedProbeStaysDownAndNonNoerrorProbeCountsAsFailure() async throws {
        let alt = Mock { q in answer(q, rcode: 2) }   // SERVFAIL for the probe
        let net = ok()
        // trip via real failures first
        let flag = FlagBox(false)
        let alt2 = Mock { q in
            if flag.value { return answer(q, rcode: 2) }
            throw UpstreamError.timeout
        }
        _ = alt
        let r = router(network: net, alt: alt2, breaker: shortBreaker())
        for _ in 0..<3 { _ = try await r.resolve(q("example.com")) }
        flag.value = true
        try await Task.sleep(nanoseconds: 300_000_000)
        _ = try await r.resolve(q("example.com"))   // starts probe
        await eventually { alt2.calls >= 4 }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(alt2.calls, 4)
        XCTAssertEqual(r.status, .fallingBack(name: "Alt"))
    }

    func testNetworkChangedNoopWhenOff() async throws {
        let alt = ok()
        let r = router(network: ok(), alt: nil)
        r.networkChanged()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(alt.calls, 0)
        XCTAssertEqual(r.status, .network)
    }

    func testNetworkChangedProbesImmediately() async throws {
        let alt = ok()
        let r = router(network: ok(), alt: alt)
        r.networkChanged()
        await eventually { alt.calls >= 1 }
        XCTAssertEqual(alt.calls, 1)
        XCTAssertEqual(r.status, .alternative(name: "Alt", encrypted: true))
    }

    func testNetworkChangedRecoversDownAlternativeUnderPolicyNone() async throws {
        let flag = FlagBox(false)
        let alt = Mock { q in
            if flag.value { return answer(q) }
            throw UpstreamError.timeout
        }
        let r = router(network: ok(), alt: alt, policy: .none)
        for _ in 0..<3 { _ = try? await r.resolve(q("example.com")) }
        XCTAssertEqual(r.status, .failing(name: "Alt"))
        flag.value = true
        r.networkChanged()
        await eventually { r.status == .alternative(name: "Alt", encrypted: true) }
        XCTAssertEqual(r.status, .alternative(name: "Alt", encrypted: true))
    }

    func testStatusUnencryptedAlternative() {
        let r = ResolverRouter(network: ok(), alternative: (ok(), "UDP", false), policy: .networkDNS)
        XCTAssertEqual(r.status, .alternative(name: "UDP", encrypted: false))
    }
}

private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Bool
    init(_ v: Bool) { self.v = v }
    var value: Bool { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
}

private final class FlakyScript: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Bool]
    init(_ items: [Bool]) { self.items = items }
    func next() -> Bool { lock.withLock { items.isEmpty ? true : items.removeFirst() } }
}
