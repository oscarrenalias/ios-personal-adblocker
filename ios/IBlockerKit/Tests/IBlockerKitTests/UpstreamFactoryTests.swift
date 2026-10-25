import XCTest
@testable import IBlockerKit
import IBlockerTunnelKit

final class UpstreamFactoryTests: XCTestCase {

    func testNetworkKindWithProviderYieldsNetworkDNSUpstream() {
        let upstream = UpstreamFactory.make(UpstreamConfig(kind: .network), interfaceIndex: { 4 })
        XCTAssertTrue(upstream is NetworkDNSUpstream)
    }


    func testNetworkKindWithoutProviderIsNil() {
        XCTAssertNil(UpstreamFactory.make(UpstreamConfig(kind: .network)))
    }

    func testNetworkUpstreamFailsWhenNoInterfaceKnown() async throws {
        let upstream = try XCTUnwrap(
            UpstreamFactory.make(UpstreamConfig(kind: .network), interfaceIndex: { nil }))
        let query = makeDNSQueryData(name: "example.com")
        do {
            _ = try await upstream.resolve(query)
            XCTFail("expected failure")
        } catch let error as UpstreamError {
            XCTAssertEqual(error, .connectionFailed("no network interface"))
        }
    }

    func testNetworkUpstreamTreatsZeroIndexAsNoInterface() async throws {
        let upstream = try XCTUnwrap(
            UpstreamFactory.make(UpstreamConfig(kind: .network), interfaceIndex: { 0 }))
        do {
            _ = try await upstream.resolve(makeDNSQueryData(name: "example.com"))
            XCTFail("expected failure")
        } catch let error as UpstreamError {
            XCTAssertEqual(error, .connectionFailed("no network interface"))
        }
    }

    func testDoHAndUDPUnchangedWithProvider() {
        let doh = UpstreamFactory.make(
            UpstreamConfig(kind: .doh, dohURL: "https://1.1.1.1/dns-query"), interfaceIndex: { nil })
        XCTAssertTrue(doh is DoHUpstream)
        let udp = UpstreamFactory.make(
            UpstreamConfig(kind: .udp, udpAddress: "1.1.1.1"), interfaceIndex: { nil })
        XCTAssertTrue(udp is UDPUpstream)
        XCTAssertNil(UpstreamFactory.make(UpstreamConfig(kind: .udp), interfaceIndex: { nil }))
    }
}
