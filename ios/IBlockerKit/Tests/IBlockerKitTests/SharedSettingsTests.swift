import XCTest
@testable import IBlockerKit

final class SharedSettingsTests: XCTestCase {

    private func makeSettings() -> (SharedSettings, String) {
        let suite = "iblocker-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (SharedSettings(defaults: defaults), suite)
    }

    func testVerboseLoggingUntilRoundTripAndExpiry() {
        let (settings, suite) = makeSettings()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        XCTAssertNil(settings.verboseLoggingUntil)
        let future = Date().addingTimeInterval(3600)
        settings.verboseLoggingUntil = future
        XCTAssertEqual(settings.verboseLoggingUntil?.timeIntervalSince1970 ?? 0,
                       future.timeIntervalSince1970, accuracy: 0.001)
        settings.verboseLoggingUntil = Date().addingTimeInterval(-1)
        XCTAssertNil(settings.verboseLoggingUntil)
        settings.verboseLoggingUntil = future
        settings.verboseLoggingUntil = nil
        XCTAssertNil(settings.verboseLoggingUntil)
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

        let resolver = ResolverSettings(useAlternative: false, alternative: network,
                                        alternativeName: "Custom", fallbackPolicy: .none)
        let data = try TunnelIPCCoder.encode(.setResolverSettings(resolver))
        guard case .setResolverSettings(let decoded) = try TunnelIPCCoder.decodeRequest(data) else {
            return XCTFail("expected setResolverSettings")
        }
        XCTAssertEqual(decoded, resolver)
        XCTAssertEqual(decoded.alternative.kind, .network)
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

    // MARK: - ResolverSettings migration

    private func makeDefaults() -> (UserDefaults, SharedSettings, String) {
        let suite = "iblocker-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (defaults, SharedSettings(defaults: defaults), suite)
    }

    func testResolverSettingsDefaultValues() {
        let d = ResolverSettings.default
        XCTAssertFalse(d.useAlternative)
        XCTAssertEqual(d.alternativeName, "Cloudflare")
        XCTAssertEqual(d.alternative, UpstreamConfig(kind: .doh, dohURL: "https://1.1.1.1/dns-query"))
        XCTAssertEqual(d.fallbackPolicy, .networkDNS)
    }

    func testResolverSettingsNoKeysGivesDefault() {
        let (_, settings, suite) = makeDefaults()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        XCTAssertEqual(settings.resolverSettings, .default)
    }

    func testResolverSettingsMigrationFromLegacyUpstream() {
        let cases: [(UpstreamConfig, String)] = [
            (UpstreamPreset.quad9.config, "Quad9"),
            (UpstreamPreset.cloudflareUDP.config, "Cloudflare (UDP)"),
            (UpstreamConfig(kind: .doh, dohURL: "https://example.net/dns-query"), "Custom"),
        ]
        for (legacy, name) in cases {
            let (defaults, settings, suite) = makeDefaults()
            defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            settings.upstreamConfig = legacy
            let before = defaults.data(forKey: SharedSettings.Keys.upstreamConfig)

            let derived = settings.resolverSettings
            XCTAssertTrue(derived.useAlternative)
            XCTAssertEqual(derived.alternative, legacy)
            XCTAssertEqual(derived.alternativeName, name)
            XCTAssertEqual(derived.fallbackPolicy, .networkDNS)

            XCTAssertNil(defaults.object(forKey: SharedSettings.Keys.resolverSettings), "read must not write")
            XCTAssertEqual(defaults.data(forKey: SharedSettings.Keys.upstreamConfig), before)
        }
    }

    func testResolverSettingsLegacyNetworkGivesDefault() {
        let (_, settings, suite) = makeDefaults()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        settings.upstreamConfig = UpstreamConfig(kind: .network)
        XCTAssertEqual(settings.resolverSettings, .default)
    }

    func testResolverSettingsStoredValueWinsAndRoundTrips() {
        let (_, settings, suite) = makeDefaults()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        settings.upstreamConfig = UpstreamPreset.quad9.config
        let stored = ResolverSettings(useAlternative: false, alternative: UpstreamPreset.adGuard.config,
                                      alternativeName: "AdGuard DNS", fallbackPolicy: .none)
        settings.resolverSettings = stored
        XCTAssertEqual(settings.resolverSettings, stored)
    }

    func testResolverSettingsCorruptDataFallsBackToDerivation() {
        let (defaults, settings, suite) = makeDefaults()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        defaults.set(Data("not json".utf8), forKey: SharedSettings.Keys.resolverSettings)
        settings.upstreamConfig = UpstreamPreset.cloudflare.config
        let derived = settings.resolverSettings
        XCTAssertTrue(derived.useAlternative)
        XCTAssertEqual(derived.alternativeName, "Cloudflare")
    }

    func testFallbackPolicyCodableRoundTrip() throws {
        for policy in FallbackPolicy.allCases {
            let data = try JSONEncoder().encode(policy)
            XCTAssertEqual(try JSONDecoder().decode(FallbackPolicy.self, from: data), policy)
        }
    }
}
