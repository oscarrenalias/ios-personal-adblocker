import XCTest
@testable import IBlockerKit

final class NetworkOnlyNamesTests: XCTestCase {

    func testMatches() {
        for name in ["1.168.192.in-addr.arpa", "epdg.epc.mnc260.mcc310.pub.3gppnetwork.org", "fritz.box",
                     "home.arpa", "printer.home.arpa", "foo.lan", "lan", "FRITZ.BOX", "fritz.box.",
                     "16.172.in-addr.arpa", "31.172.in-addr.arpa", "5.16.172.in-addr.arpa"] {
            XCTAssertTrue(NetworkOnlyNames.matches(name), name)
        }
    }

    func testNonMatches() {
        for name in ["example.com", "notlocal.com", "local", "printer.local", "15.172.in-addr.arpa",
                     "32.172.in-addr.arpa", "notlan", "xlan.com", "", ".", "a..fritz.box", "xfritz.box"] {
            XCTAssertFalse(NetworkOnlyNames.matches(name), name)
        }
    }

    func testDnsSdWildcards() {
        XCTAssertTrue(NetworkOnlyNames.matches("b._dns-sd._udp.0.1.168.192.in-addr.arpa".replacingOccurrences(of: "0.1.168.192", with: "X")))
        XCTAssertTrue(NetworkOnlyNames.matches("lb._dns-sd._udp.X.in-addr.arpa"))
        XCTAssertTrue(NetworkOnlyNames.matches("sub.b._dns-sd._udp.X.in-addr.arpa"))
        XCTAssertFalse(NetworkOnlyNames.matches("b._dns-sd._udp.in-addr.arpa"))
        XCTAssertFalse(NetworkOnlyNames.matches("b._dns-sd._udp.X.Y.in-addr.arpa"))
    }
}
