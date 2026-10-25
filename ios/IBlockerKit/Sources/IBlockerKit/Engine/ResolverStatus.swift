import Foundation

/// Which resolver is currently answering queries, and how healthy it is.
public enum ResolverStatus: Codable, Sendable, Equatable {
    /// Using the current network's own DNS.
    case network
    /// Using the user-selected alternative upstream.
    case alternative(name: String, encrypted: Bool)
    /// The selected upstream failed; answering via network DNS instead.
    case fallingBack(name: String)
    /// The selected upstream failed and no fallback is answering.
    case failing(name: String)
}
