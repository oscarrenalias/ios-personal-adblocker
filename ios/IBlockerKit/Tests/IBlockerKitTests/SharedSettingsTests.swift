import XCTest
@testable import IBlockerKit

final class SharedSettingsTests: XCTestCase {

    private func makeSettings() -> (SharedSettings, String) {
        let suite = "iblocker-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (SharedSettings(defaults: defaults), suite)
    }

    func testRelayStrategyDefaultsToBlockDomains() {
        let (settings, suite) = makeSettings()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        XCTAssertEqual(settings.relayStrategy, .blockDomains)
    }

    func testRelayStrategyRoundTrip() {
        let (settings, suite) = makeSettings()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        settings.relayStrategy = .autoSuspend
        XCTAssertEqual(settings.relayStrategy, .autoSuspend)
        settings.relayStrategy = .keepRelay
        XCTAssertEqual(settings.relayStrategy, .keepRelay)
        settings.relayStrategy = .blockDomains
        XCTAssertEqual(settings.relayStrategy, .blockDomains)
    }

    /// Storage round-trips whatever it is given, but the tunnel must not act on
    /// a stored choice the user has no UI to change back.
    func testEffectiveRelayStrategyIgnoresStoredValueWhileControlsHidden() throws {
        try XCTSkipIf(FeatureFlags.showAppleRelayControls, "Relay controls are visible")
        let (settings, suite) = makeSettings()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        settings.relayStrategy = .autoSuspend
        XCTAssertEqual(settings.relayStrategy, .autoSuspend)
        XCTAssertEqual(settings.effectiveRelayStrategy, .blockDomains)
    }

    func testUpstreamConfigRoundTrip() {
        let (settings, suite) = makeSettings()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        XCTAssertEqual(settings.upstreamConfig, .default)
        let custom = UpstreamConfig(kind: .udp, udpAddress: "9.9.9.9")
        settings.upstreamConfig = custom
        XCTAssertEqual(settings.upstreamConfig, custom)
    }

    // MARK: - .network upstream

    func testDefaultUpstreamIsNetworkDNS() {
        XCTAssertEqual(UpstreamConfig.default.kind, .network)
        XCTAssertEqual(UpstreamConfig.default.displayName, "Network DNS")
        XCTAssertEqual(UpstreamConfig(kind: .network).displayName, "Network DNS")
        XCTAssertEqual(UpstreamConfig(kind: .doh, dohURL: "https://1.1.1.1/dns-query").displayName,
                       "https://1.1.1.1/dns-query")
        XCTAssertEqual(UpstreamConfig(kind: .udp, udpAddress: "9.9.9.9").displayName, "9.9.9.9:53 (UDP)")
    }

    func testNetworkConfigRoundTripsThroughSharedSettingsAndIPC() throws {
        let (settings, suite) = makeSettings()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let network = UpstreamConfig(kind: .network)
        settings.upstreamConfig = UpstreamConfig(kind: .udp, udpAddress: "9.9.9.9")
        settings.upstreamConfig = network
        XCTAssertEqual(settings.upstreamConfig, network)

        let data = try TunnelIPCCoder.encode(.setUpstream(network))
        guard case .setUpstream(let decoded) = try TunnelIPCCoder.decodeRequest(data) else {
            return XCTFail("expected setUpstream")
        }
        XCTAssertEqual(decoded, network)
        XCTAssertEqual(decoded.kind, .network)
    }

    func testStoredDoHConfigStillDecodesUnchanged() throws {
        let (settings, suite) = makeSettings()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let doh = UpstreamConfig(kind: .doh, dohURL: "https://1.1.1.1/dns-query")
        settings.upstreamConfig = doh
        XCTAssertEqual(settings.upstreamConfig, doh)

        let legacy = Data(#"{"kind":"doh","dohURL":"https://94.140.14.14/dns-query"}"#.utf8)
        let decoded = try JSONDecoder().decode(UpstreamConfig.self, from: legacy)
        XCTAssertEqual(decoded, UpstreamConfig(kind: .doh, dohURL: "https://94.140.14.14/dns-query"))
        let udp = try JSONDecoder().decode(UpstreamConfig.self, from: Data(#"{"kind":"udp","udpAddress":"1.1.1.1"}"#.utf8))
        XCTAssertEqual(udp, UpstreamConfig(kind: .udp, udpAddress: "1.1.1.1"))
    }
}
