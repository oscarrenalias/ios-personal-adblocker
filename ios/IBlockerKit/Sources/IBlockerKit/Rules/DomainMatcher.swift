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

    /// Which set a match came from.
    public enum MatchSource: Equatable, Sendable {
        case userAllowlist, userDenylist, builtIn
        case listException(sourceNumber: UInt8)   // 0 = unknown list
        case list(sourceNumber: UInt8)            // 0 = unknown list
    }

    /// A match in one set, with the suffix of the name that hit.
    public struct Match: Equatable, Sendable {
        public let source: MatchSource
        public let matchedSuffix: String
    }

    public struct Explanation: Equatable, Sendable {
        public let verdict: Verdict
        /// nil when `verdict == .none`.
        public let decidingMatch: Match?
    }

    /// Result of a single precedence walk. Records only the label count of
    /// the matching suffix; the suffix string is built on demand.
    struct Hit: Sendable, Equatable {
        let source: MatchSource
        let matchedLabelCount: Int

        var verdict: Verdict {
            switch source {
            case .userAllowlist, .listException: return .allow
            case .userDenylist, .builtIn, .list: return .block
            }
        }
    }

    public func verdict(for domain: String) -> Verdict {
        explain(domain).verdict
    }

    /// Verdict plus the deciding match, from the same lookup as `verdict(for:)`.
    public func explain(_ domain: String) -> Explanation {
        guard let hit = hit(for: domain) else {
            return Explanation(verdict: .none, decidingMatch: nil)
        }
        return Explanation(verdict: hit.verdict,
                           decidingMatch: Match(source: hit.source,
                                                matchedSuffix: Self.suffix(of: domain, labelCount: hit.matchedLabelCount)))
    }

    /// Every match in every set, in precedence order; within a set the most
    /// specific suffix comes first.
    public func allMatches(for domain: String) -> [Match] {
        let hashes = Self.suffixHashes(of: domain)
        guard !hashes.isEmpty else { return [] }
        let labelBase = hashes.count + 1
        var result: [Match] = []

        func collect(_ source: (Int) -> MatchSource?) {
            for i in hashes.indices {
                if let found = source(i) {
                    result.append(Match(source: found,
                                        matchedSuffix: Self.suffix(of: domain, labelCount: labelBase - i)))
                }
            }
        }
        if let allow = userAllowlist, !allow.isEmpty {
            collect { allow.contains(hashes[$0]) ? .userAllowlist : nil }
        }
        if let deny = userDenylist, !deny.isEmpty {
            collect { deny.contains(hashes[$0]) ? .userDenylist : nil }
        }
        if !builtInBlockHashes.isEmpty {
            collect { builtInBlockHashes.contains(hashes[$0]) ? .builtIn : nil }
        }
        if let exceptions = listAllowlist, !exceptions.isEmpty {
            collect { exceptions.lookup(hashes[$0]).map { .listException(sourceNumber: $0) } }
        }
        if let block = blocklist, !block.isEmpty {
            collect { block.lookup(hashes[$0]).map { .list(sourceNumber: $0) } }
        }
        return result
    }

    /// The last `labelCount` labels of `domain`.
    private static func suffix(of domain: String, labelCount: Int) -> String {
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        return labels.suffix(labelCount).joined(separator: ".")
    }

    /// Single walk over the suffix hashes in precedence order. Hashes are
    /// most-specific first, so index `i` has `hashes.count + 1 - i` labels.
    func hit(for domain: String) -> Hit? {
        let hashes = Self.suffixHashes(of: domain)
        guard !hashes.isEmpty else { return nil }
        let labelBase = hashes.count + 1

        if let allow = userAllowlist, !allow.isEmpty {
            for (i, hash) in hashes.enumerated() where allow.contains(hash) {
                return Hit(source: .userAllowlist, matchedLabelCount: labelBase - i)
            }
        }
        if let deny = userDenylist, !deny.isEmpty {
            for (i, hash) in hashes.enumerated() where deny.contains(hash) {
                return Hit(source: .userDenylist, matchedLabelCount: labelBase - i)
            }
        }
        if !builtInBlockHashes.isEmpty {
            for (i, hash) in hashes.enumerated() where builtInBlockHashes.contains(hash) {
                return Hit(source: .builtIn, matchedLabelCount: labelBase - i)
            }
        }
        if let exceptions = listAllowlist, !exceptions.isEmpty {
            for (i, hash) in hashes.enumerated() {
                if let number = exceptions.lookup(hash) {
                    return Hit(source: .listException(sourceNumber: number), matchedLabelCount: labelBase - i)
                }
            }
        }
        if let block = blocklist, !block.isEmpty {
            for (i, hash) in hashes.enumerated() {
                if let number = block.lookup(hash) {
                    return Hit(source: .list(sourceNumber: number), matchedLabelCount: labelBase - i)
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
