import Foundation

/// A named alternative-resolver choice. `name` is short and unique (stored in
/// settings and shown in status); `label` is what the picker shows.
/// Network DNS is deliberately not a preset.
public struct UpstreamPreset: Sendable, Equatable, Identifiable {
    public let name: String
    public let label: String
    public let config: UpstreamConfig

    public var id: String { name }

    public init(name: String, label: String, config: UpstreamConfig) {
        self.name = name
        self.label = label
        self.config = config
    }

    /// Name used for any config that matches no preset.
    public static let customName = "Custom"

    public static let cloudflare = UpstreamPreset(
        name: "Cloudflare",
        label: "Cloudflare (DoH)",
        config: UpstreamConfig(kind: .doh, dohURL: "https://1.1.1.1/dns-query"))

    public static let adGuard = UpstreamPreset(
        name: "AdGuard DNS",
        label: "AdGuard DNS (DoH, extra blocking)",
        config: UpstreamConfig(kind: .doh, dohURL: "https://94.140.14.14/dns-query"))

    public static let quad9 = UpstreamPreset(
        name: "Quad9",
        label: "Quad9 (DoH, malware blocking)",
        config: UpstreamConfig(kind: .doh, dohURL: "https://9.9.9.9:5053/dns-query"))

    public static let cloudflareUDP = UpstreamPreset(
        name: "Cloudflare (UDP)",
        label: "Cloudflare (UDP 53, unencrypted)",
        config: UpstreamConfig(kind: .udp, udpAddress: "1.1.1.1"))

    public static let quad9UDP = UpstreamPreset(
        name: "Quad9 (UDP)",
        label: "Quad9 (UDP 53, unencrypted)",
        config: UpstreamConfig(kind: .udp, udpAddress: "9.9.9.9"))

    public static let all: [UpstreamPreset] = [
        cloudflare, adGuard, quad9, cloudflareUDP, quad9UDP,
    ]

    /// The preset name matching `config`, or "Custom" when none matches.
    public static func name(for config: UpstreamConfig) -> String {
        all.first { $0.config == config }?.name ?? customName
    }
}
