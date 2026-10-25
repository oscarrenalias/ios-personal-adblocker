import Foundation
import IBlockerKit

/// Builds the concrete upstream for a stored configuration.
public enum UpstreamFactory {
    /// Interface-less entry point. `.network` needs a physical interface
    /// provider, so it yields nil here (callers surface SERVFAIL / invalid
    /// config); use `make(_:interfaceIndex:)` to build it.
    public static func make(_ config: UpstreamConfig) -> DNSUpstream? {
        switch config.kind {
        case .doh:
            return DoHUpstream(config: config)
        case .udp:
            guard let address = config.udpAddress, !address.isEmpty else { return nil }
            return UDPUpstream(address: address)
        case .network:
            return nil
        }
    }

    /// Provider-aware entry point: routes `.network` to `NetworkDNSUpstream`
    /// using the injected physical-interface closure; other kinds are built
    /// exactly as in `make(_:)`.
    public static func make(
        _ config: UpstreamConfig,
        interfaceIndex: @escaping NetworkDNSUpstream.InterfaceIndexProvider
    ) -> DNSUpstream? {
        if config.kind == .network {
            return NetworkDNSUpstream(interfaceIndex: interfaceIndex)
        }
        return make(config)
    }
}
