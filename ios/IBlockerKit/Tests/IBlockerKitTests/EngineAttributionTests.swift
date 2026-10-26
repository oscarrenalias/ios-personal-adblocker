import XCTest
@testable import IBlockerKit

private final class RouteUpstream: DNSUpstream, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    let result: @Sendable (Data) async throws -> (Data, UpstreamRoute)
    init(_ result: @escaping @Sendable (Data) async throws -> (Data, UpstreamRoute)) { self.result = result }
    var calls: Int { lock.withLock { _calls } }
    func resolve(_ query: Data) async throws -> Data { try await resolveWithRoute(query).0 }
    func resolveWithRoute(_ query: Data) async throws -> (Data, UpstreamRoute) {
        lock.withLock { _calls += 1 }
        return try await result(query)
    }
}

/// Echo of the query with QR set and one A answer, so the cache will store it.
private func answerWithA(_ query: Data) -> Data {
    var b = [UInt8](query)
    guard b.count >= 12 else { return query }
    b[2] |= 0x80
    b[7] = 1
    b.append(contentsOf: [0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 1, 0x2C, 0, 4, 1, 2, 3, 4])
    return Data(b)
}

final class EngineAttributionTests: XCTestCase {

    private var paths: AppGroupPaths!

    override func setUpWithError() throws {
        paths = AppGroupPaths(containerURL: try makeTempDirectory())
        try paths.ensureDirectories()
        try writeV2Blob([("list.example.com", 3), ("wide.example.net", 3)], to: paths.blocklistURL)
        try writeV2Blob([("exc.wide.example.net", 5)], to: paths.listAllowlistURL)
        try writeV1Blob(["allowed.example.com"], to: paths.userAllowlistURL)
        try writeV1Blob(["deny.example.com"], to: paths.userDenylistURL)
    }

    private func makeEngine(upstream: DNSUpstream, configuration: DNSProxyEngine.Configuration = .init())
        throws -> DNSProxyEngine {
        DNSProxyEngine(
            matcher: paths.loadMatcher(builtInBlockHashes: [FNV1a.hash64("builtin.example.com")]),
            upstream: upstream,
            logWriter: try QueryLogRingWriter(url: paths.queryLogURL, capacity: 1024),
            statsURL: paths.statsURL,
            configuration: configuration)
    }

    private func send(_ engine: DNSProxyEngine, _ name: String, qtype: UInt16 = DNSRecordType.a) async {
        _ = await engine.handlePacket(makeUDPPacketV4(payload: [UInt8](makeDNSQueryData(name: name, qtype: qtype))))
    }

    private func lastRecord(_ engine: DNSProxyEngine) async throws -> QueryLogRecord {
        await engine.flush()
        let (records, _) = QueryLogRingReader(url: paths.queryLogURL).read(since: 0)
        return try XCTUnwrap(records.last)
    }

    private func forwarding(_ route: UpstreamRoute = .network) -> RouteUpstream {
        RouteUpstream { (answerWithA($0), route) }
    }

    func testBlockedByList() async throws {
        let upstream = forwarding()
        let engine = try makeEngine(upstream: upstream)
        await send(engine, "a.b.list.example.com")
        let r = try await lastRecord(engine)
        XCTAssertEqual(r.verdict, .blocked)
        XCTAssertEqual(r.source, 6)
        XCTAssertEqual(r.details?.sourceNumber, 3)
        XCTAssertEqual(r.details?.matchedLabels, 3)
        XCTAssertEqual(r.details?.cacheHit, false)
        XCTAssertEqual(r.details?.route, .unknown)
        XCTAssertEqual(upstream.calls, 0)
    }

    func testUserAllowUserDenyAndBuiltIn() async throws {
        let engine = try makeEngine(upstream: forwarding())
        await send(engine, "www.allowed.example.com")
        var r = try await lastRecord(engine)
        XCTAssertEqual(r.verdict, .allowed)
        XCTAssertEqual(r.source, 2)
        XCTAssertEqual(r.details?.matchedLabels, 3)

        await send(engine, "deny.example.com")
        r = try await lastRecord(engine)
        XCTAssertEqual(r.verdict, .blocked)
        XCTAssertEqual(r.source, 3)
        XCTAssertEqual(r.details?.sourceNumber, 0)

        await send(engine, "x.builtin.example.com")
        r = try await lastRecord(engine)
        XCTAssertEqual(r.verdict, .blocked)
        XCTAssertEqual(r.source, 4)
    }

    func testListExceptionAllowed() async throws {
        let engine = try makeEngine(upstream: forwarding(.alternative))
        await send(engine, "x.exc.wide.example.net")
        let r = try await lastRecord(engine)
        XCTAssertEqual(r.verdict, .allowed)
        XCTAssertEqual(r.source, 5)
        XCTAssertEqual(r.details?.sourceNumber, 5)
        XCTAssertEqual(r.details?.matchedLabels, 4)
        XCTAssertEqual(r.details?.route, .alternative)
    }

    func testNoRuleAllowedRecordsSourceOne() async throws {
        let engine = try makeEngine(upstream: forwarding())
        await send(engine, "www.apple.com")
        let r = try await lastRecord(engine)
        XCTAssertEqual(r.verdict, .allowed)
        XCTAssertEqual(r.source, 1)
        XCTAssertEqual(r.details?.sourceNumber, 0)
        XCTAssertEqual(r.details?.matchedLabels, 0)
    }

    func testCacheHitSetsCacheFlagAndRouteZero() async throws {
        let upstream = forwarding(.fallback)
        let engine = try makeEngine(upstream: upstream)
        await send(engine, "cached.example.org")
        var r = try await lastRecord(engine)
        XCTAssertEqual(r.details?.cacheHit, false)
        XCTAssertEqual(r.details?.route, .fallback)
        await send(engine, "cached.example.org")
        r = try await lastRecord(engine)
        XCTAssertEqual(upstream.calls, 1)
        XCTAssertEqual(r.details?.cacheHit, true)
        XCTAssertEqual(r.details?.route, .unknown)
        XCTAssertEqual(r.verdict, .allowed)
    }

    func testAllowedRoutesAreRecorded() async throws {
        for (route, expected) in [(UpstreamRoute.alternative, LogRoute.alternative), (.network, .network),
                                  (.fallback, .fallback), (.networkOnlyName, .networkOnlyName), (.local, .local)] {
            paths = AppGroupPaths(containerURL: try makeTempDirectory())
            try paths.ensureDirectories()
            let engine = try makeEngine(upstream: forwarding(route))
            await send(engine, "r.example.org")
            let r = try await lastRecord(engine)
            XCTAssertEqual(r.details?.route, expected, "\(route)")
        }
    }

    func testRoutedErrorFailsWithRouteFromError() async throws {
        let engine = try makeEngine(upstream: RouteUpstream { _ in
            throw RoutedError(route: .fallback, underlying: UpstreamError.timeout)
        })
        await send(engine, "fail.example.org")
        let r = try await lastRecord(engine)
        XCTAssertEqual(r.verdict, .failed)
        XCTAssertEqual(r.details?.route, .fallback)
        XCTAssertEqual(r.source, 1)
    }

    func testPlainErrorFailsWithRouteZero() async throws {
        let engine = try makeEngine(upstream: RouteUpstream { _ in throw UpstreamError.timeout })
        await send(engine, "fail.example.org")
        let r = try await lastRecord(engine)
        XCTAssertEqual(r.verdict, .failed)
        XCTAssertEqual(r.details?.route, .unknown)
    }

    func testInFlightLimitFailure() async throws {
        let upstream = forwarding()
        let engine = try makeEngine(upstream: upstream, configuration: .init(maxInFlight: 0))
        await send(engine, "busy.example.org")
        let r = try await lastRecord(engine)
        XCTAssertEqual(r.verdict, .failed)
        XCTAssertEqual(r.details?.route, .unknown)
        XCTAssertEqual(r.details?.cacheHit, false)
        XCTAssertEqual(upstream.calls, 0)
    }

    func testPausedRecordsSourceSevenAndSkipsMatcher() async throws {
        let engine = try makeEngine(upstream: forwarding())
        await engine.setPaused(until: Date().addingTimeInterval(60))
        await send(engine, "a.list.example.com")
        let r = try await lastRecord(engine)
        XCTAssertEqual(r.verdict, .allowed)
        XCTAssertEqual(r.source, 7)
        XCTAssertEqual(r.details?.sourceNumber, 0)
        XCTAssertEqual(r.details?.matchedLabels, 0)
    }

    func testNonINClassRecordsSourceOne() async throws {
        let engine = try makeEngine(upstream: forwarding())
        var bytes = [UInt8](makeDNSQueryData(name: "a.list.example.com"))
        bytes[bytes.count - 1] = 3   // CH class
        _ = await engine.handlePacket(makeUDPPacketV4(payload: bytes))
        let r = try await lastRecord(engine)
        XCTAssertEqual(r.verdict, .allowed)
        XCTAssertEqual(r.source, 1)
    }

    func testUnparseableQueryWritesNoRecord() async throws {
        let upstream = forwarding()
        let engine = try makeEngine(upstream: upstream)
        _ = await engine.handlePacket(makeUDPPacketV4(payload: [0, 1, 2, 3, 4]))
        await engine.flush()
        XCTAssertTrue(QueryLogRingReader(url: paths.queryLogURL).read(since: 0).records.isEmpty)
    }
}

// MARK: - Router route reporting

private final class StubUpstream: DNSUpstream, @unchecked Sendable {
    let fail: Bool
    init(fail: Bool = false) { self.fail = fail }
    func resolve(_ query: Data) async throws -> Data {
        if fail { throw UpstreamError.timeout }
        var b = [UInt8](query); b[2] |= 0x80
        return Data(b)
    }
}

final class ResolverRouterRouteTests: XCTestCase {
    private func router(alt: StubUpstream?, net: StubUpstream = StubUpstream(),
                        policy: FallbackPolicy = .networkDNS) -> ResolverRouter {
        ResolverRouter(network: net, alternative: alt.map { ($0, "Alt", true) }, policy: policy)
    }
    private func q(_ n: String) -> Data { makeDNSQueryData(name: n) }

    func testRoutes() async throws {
        let local = try await router(alt: StubUpstream()).resolveWithRoute(q("printer.local"))
        XCTAssertEqual(local.1, .local)
        let off = try await router(alt: nil).resolveWithRoute(q("example.com"))
        XCTAssertEqual(off.1, .network)
        let onlyName = try await router(alt: StubUpstream()).resolveWithRoute(q("fritz.box"))
        XCTAssertEqual(onlyName.1, .networkOnlyName)
        let alt = try await router(alt: StubUpstream()).resolveWithRoute(q("example.com"))
        XCTAssertEqual(alt.1, .alternative)
        let fallback = try await router(alt: StubUpstream(fail: true)).resolveWithRoute(q("example.com"))
        XCTAssertEqual(fallback.1, .fallback)
    }

    func testFailingAlternativeWithPolicyNone() async throws {
        let r = router(alt: StubUpstream(fail: true), policy: .none)
        do {
            _ = try await r.resolveWithRoute(q("example.com"))
            XCTFail("expected throw")
        } catch let error as RoutedError {
            XCTAssertEqual(error.route, .alternative)
        }
        do {
            _ = try await r.resolve(q("example.com"))
            XCTFail("expected throw")
        } catch let error as ResolverRouterError {
            guard case .alternativeFailed = error else { return XCTFail("wrong case") }
        }
    }

    func testFailingNetworkThrowsRoutedErrorWithRoute() async throws {
        let cases: [(ResolverRouter, UpstreamRoute)] = [
            (router(alt: nil, net: StubUpstream(fail: true)), .network),
            (router(alt: StubUpstream(), net: StubUpstream(fail: true)), .networkOnlyName),
            (router(alt: StubUpstream(fail: true), net: StubUpstream(fail: true)), .fallback),
        ]
        let names = ["example.com", "fritz.box", "example.com"]
        for ((r, route), name) in zip(cases, names) {
            do {
                _ = try await r.resolveWithRoute(q(name))
                XCTFail("expected throw")
            } catch let error as RoutedError {
                XCTAssertEqual(error.route, route)
            }
        }
    }

    func testDefaultRouteForPlainUpstreamIsNetwork() async throws {
        let (_, route) = try await StubUpstream().resolveWithRoute(q("example.com"))
        XCTAssertEqual(route, .network)
    }
}
