import XCTest
@testable import IBlockerKit
@testable import IBlockerTunnelKit

final class DoHUpstreamTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var count: Int { lock.withLock { n } }
        func bump() { lock.withLock { n += 1 } }
    }

    func testResetConnectionReplacesSession() {
        let counter = Counter()
        let doh = DoHUpstream(url: URL(string: "https://1.1.1.1/dns-query")!) { config in
            counter.bump()
            return URLSession(configuration: config)
        }
        let first = doh.session
        XCTAssertEqual(counter.count, 1)
        doh.resetConnection(reason: "timeout")
        XCTAssertEqual(counter.count, 2)
        XCTAssertFalse(doh.session === first)
    }
}
