import XCTest
@testable import IBlockerKit

final class ResolverIPCTests: XCTestCase {

    func testResolverStatusCodableAndEquatable() throws {
        let all: [ResolverStatus] = [
            .network,
            .alternative(name: "Cloudflare", encrypted: true),
            .fallingBack(name: "Quad9"),
            .failing(name: "Quad9"),
        ]
        for status in all {
            let data = try JSONEncoder().encode(status)
            XCTAssertEqual(try JSONDecoder().decode(ResolverStatus.self, from: data), status)
        }
        XCTAssertNotEqual(ResolverStatus.alternative(name: "A", encrypted: true),
                          .alternative(name: "A", encrypted: false))
        XCTAssertNotEqual(ResolverStatus.alternative(name: "A", encrypted: true),
                          .alternative(name: "B", encrypted: true))
        XCTAssertNotEqual(ResolverStatus.fallingBack(name: "A"), .failing(name: "A"))
        XCTAssertNotEqual(ResolverStatus.fallingBack(name: "A"), .fallingBack(name: "B"))
    }

    func testIsEncrypted() {
        XCTAssertTrue(UpstreamConfig(kind: .doh, dohURL: "https://1.1.1.1/dns-query").isEncrypted)
        XCTAssertFalse(UpstreamConfig(kind: .udp, udpAddress: "1.1.1.1").isEncrypted)
        XCTAssertFalse(UpstreamConfig(kind: .network).isEncrypted)
    }

    func testRuntimeStatsRoundTripWithAndWithoutStatus() throws {
        for status in [nil, ResolverStatus.alternative(name: "Cloudflare", encrypted: true)] {
            let stats = TunnelRuntimeStats(totalQueries: 5, blockedQueries: 2, resolverStatus: status)
            let data = try TunnelIPCCoder.encode(.stats(stats))
            guard case .stats(let decoded) = try TunnelIPCCoder.decodeResponse(data) else {
                return XCTFail("expected stats")
            }
            XCTAssertEqual(decoded, stats)
            XCTAssertEqual(decoded.resolverStatus, status)
        }
    }

    func testRuntimeStatsDecodesWithoutResolverStatusKey() throws {
        let json = Data(#"{"totalQueries":3,"blockedQueries":1,"blocklistEntryCount":0}"#.utf8)
        let decoded = try JSONDecoder().decode(TunnelRuntimeStats.self, from: json)
        XCTAssertNil(decoded.resolverStatus)
        XCTAssertEqual(decoded.totalQueries, 3)
    }

    func testSetResolverSettingsRoundTrip() throws {
        let settings = ResolverSettings(useAlternative: true, alternative: UpstreamPreset.quad9.config,
                                        alternativeName: "Quad9", fallbackPolicy: .none)
        let data = try TunnelIPCCoder.encode(.setResolverSettings(settings))
        guard case .setResolverSettings(let decoded) = try TunnelIPCCoder.decodeRequest(data) else {
            return XCTFail("expected setResolverSettings")
        }
        XCTAssertEqual(decoded, settings)
    }
}

final class UpstreamPresetTests: XCTestCase {

    func testAllPresets() {
        let all = UpstreamPreset.all
        XCTAssertEqual(all.map(\.name), [
            "Cloudflare", "Cloudflare (malware blocking)", "Cloudflare (family)",
            "AdGuard DNS", "Quad9", "Cloudflare (UDP)", "Quad9 (UDP)",
        ])
        XCTAssertEqual(all.map(\.label), [
            "Cloudflare (DoH)",
            "Cloudflare (DoH, malware blocking)",
            "Cloudflare (DoH, malware + adult content blocking)",
            "AdGuard DNS (DoH, extra blocking)",
            "Quad9 (DoH, malware blocking)",
            "Cloudflare (UDP 53, unencrypted)",
            "Quad9 (UDP 53, unencrypted)",
        ])
        XCTAssertEqual(Set(all.map(\.name)).count, 7)
        XCTAssertTrue(UpstreamPreset.cloudflareUDP.label.contains("unencrypted"))
        XCTAssertTrue(UpstreamPreset.quad9UDP.label.contains("unencrypted"))
        XCTAssertEqual(all[0].config, UpstreamConfig(kind: .doh, dohURL: "https://1.1.1.1/dns-query"))
        XCTAssertEqual(all[1].config, UpstreamConfig(kind: .doh, dohURL: "https://1.1.1.2/dns-query"))
        XCTAssertEqual(all[2].config, UpstreamConfig(kind: .doh, dohURL: "https://1.1.1.3/dns-query"))
        XCTAssertEqual(all[3].config, UpstreamConfig(kind: .doh, dohURL: "https://94.140.14.14/dns-query"))
        XCTAssertEqual(all[4].config, UpstreamConfig(kind: .doh, dohURL: "https://9.9.9.9/dns-query"))
        XCTAssertEqual(all[5].config, UpstreamConfig(kind: .udp, udpAddress: "1.1.1.1"))
        XCTAssertEqual(all[6].config, UpstreamConfig(kind: .udp, udpAddress: "9.9.9.9"))
    }

    func testMalwareBlockingConfigNamesCloudflareMalware() {
        XCTAssertEqual(
            UpstreamPreset.name(for: UpstreamConfig(kind: .doh, dohURL: "https://1.1.1.2/dns-query")),
            "Cloudflare (malware blocking)")
    }

    func testQuad9TunnelDoHURLUsesPort443() {
        XCTAssertEqual(DNSProviderPreset.quad9.tunnelDoHURL, "https://9.9.9.9/dns-query")
        XCTAssertEqual(DNSProviderPreset.quad9.serverURL, "https://dns.quad9.net/dns-query")
    }

    func testNameForConfig() {
        for preset in UpstreamPreset.all {
            XCTAssertEqual(UpstreamPreset.name(for: preset.config), preset.name)
        }
        XCTAssertEqual(UpstreamPreset.name(for: UpstreamConfig(kind: .network)), "Custom")
        XCTAssertEqual(UpstreamPreset.name(for: UpstreamConfig(kind: .doh, dohURL: "https://8.8.8.8/dns-query")), "Custom")
        XCTAssertEqual(UpstreamPreset.name(for: UpstreamConfig(kind: .udp, udpAddress: "8.8.8.8")), "Custom")
        XCTAssertEqual(UpstreamPreset.name(for: UpstreamConfig(kind: .doh, dohURL: "https://1.1.1.1/other")), "Custom")
    }
}
