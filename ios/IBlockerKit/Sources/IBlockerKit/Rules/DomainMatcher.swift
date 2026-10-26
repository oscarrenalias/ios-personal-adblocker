import Foundation

public enum Verdict: Sendable, Equatable {
    case allow
    case block
    case none
}

/// Decides the fate of a queried domain.
///
/// Precedence: user allowlist > user denylist > built-in > list exceptions
/// (`@@`, matched at any suffix, overriding list blocks) > compiled blocklist.
/// A name matches when the exact name or any parent suffix down to two
/// labels is in a set — `x.ads.example.com` matches an `ads.example.com`
/// entry; bare TLDs never match.
public struct DomainMatcher: Sendable {
    public let blocklist: CompiledBlocklistView?
    public let userAllowlist: CompiledBlocklistView?
    public let userDenylist: CompiledBlocklistView?
    /// In-memory always-on rules (the seed fallback). Independent of the
    /// compiled blobs so the tunnel keeps its guaranteed floor even when the
    /// on-disk blocklist is missing or predates an app update.
    public let builtInBlockHashes: Set<UInt64>
    /// List-level `@@` exceptions (listallow.bin). A hit on the name or any
    /// parent suffix allows it, overriding blocklist (not user/built-in) hits.
    public let listAllowlist: CompiledBlocklistView?

    public init(blocklist: CompiledBlocklistView?,
                userAllowlist: CompiledBlocklistView? = nil,
                userDenylist: CompiledBlocklistView? = nil,
                builtInBlockHashes: Set<UInt64> = [],
                listAllowlist: CompiledBlocklistView? = nil) {
        self.listAllowlist = listAllowlist
        self.blocklist = blocklist
        self.userAllowlist = userAllowlist
        self.userDenylist = userDenylist
        self.builtInBlockHashes = builtInBlockHashes
    }

    public static let empty = DomainMatcher(blocklist: nil)

    public var blockedEntryCount: Int { (blocklist?.count ?? 0) + builtInBlockHashes.count }

    /// Which tier decided a lookup.
    enum MatchTier: Sendable, Equatable {
        case userAllow, userDeny, builtIn, listException, blocklist
    }

    /// Result of a single precedence walk: the deciding tier, the number of
    /// labels in the matching suffix, and the blocklist source number (only
    /// for `.blocklist` hits).
    struct Match: Sendable, Equatable {
        let tier: MatchTier
        let matchedLabelCount: Int
        let source: UInt8?

        var verdict: Verdict {
            switch tier {
            case .userAllow, .listException: return .allow
            case .userDeny, .builtIn, .blocklist: return .block
            }
        }
    }

    public func verdict(for domain: String) -> Verdict {
        Self.verdict(of: match(for: domain))
    }

    private static func verdict(of match: Match?) -> Verdict {
        match?.verdict ?? .none
    }

    /// Single walk over the suffix hashes in precedence order. Hashes are
    /// most-specific first, so index `i` has `hashes.count + 1 - i` labels.
    func match(for domain: String) -> Match? {
        let hashes = Self.suffixHashes(of: domain)
        guard !hashes.isEmpty else { return nil }
        let labelBase = hashes.count + 1

        if let allow = userAllowlist, !allow.isEmpty {
            for (i, hash) in hashes.enumerated() where allow.contains(hash) {
                return Match(tier: .userAllow, matchedLabelCount: labelBase - i, source: nil)
            }
        }
        if let deny = userDenylist, !deny.isEmpty {
            for (i, hash) in hashes.enumerated() where deny.contains(hash) {
                return Match(tier: .userDeny, matchedLabelCount: labelBase - i, source: nil)
            }
        }
        if !builtInBlockHashes.isEmpty {
            for (i, hash) in hashes.enumerated() where builtInBlockHashes.contains(hash) {
                return Match(tier: .builtIn, matchedLabelCount: labelBase - i, source: nil)
            }
        }
        if let exceptions = listAllowlist, !exceptions.isEmpty {
            for (i, hash) in hashes.enumerated() where exceptions.contains(hash) {
                return Match(tier: .listException, matchedLabelCount: labelBase - i, source: nil)
            }
        }
        if let block = blocklist, !block.isEmpty {
            for (i, hash) in hashes.enumerated() {
                if let source = block.lookup(hash) {
                    return Match(tier: .blocklist, matchedLabelCount: labelBase - i, source: source)
                }
            }
        }
        return nil
    }

    /// FNV-1a hashes of the name and each parent suffix with ≥2 labels,
    /// most-specific first: a.b.example.com → [a.b.example.com, b.example.com, example.com]
    public static func suffixHashes(of domain: String) -> [UInt64] {
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return [] }
        var hashes: [UInt64] = []
        hashes.reserveCapacity(labels.count - 1)
        for start in 0...(labels.count - 2) {
            hashes.append(FNV1a.hash64(labels[start...].joined(separator: ".")))
        }
        return hashes
    }
}
