import Foundation

public struct CompileStats: Sendable, Equatable {
    public var blockedEntryCount: Int = 0
    public var listAllowEntryCount: Int = 0
    public var userAllowEntryCount: Int = 0
    public var userDenyEntryCount: Int = 0
    public var skippedLines: Int = 0
    public var perSourceCounts: [String: Int] = [:]
    public var generation: UInt32 = 0

    public init() {}
}

/// Turns cached list texts + user allow/deny into the three compiled blobs
/// the tunnel mmaps. Runs in the app process, where memory is plentiful.
public enum BlocklistCompiler {

    @discardableResult
    public static func compile(
        state: inout FilterListState,
        paths: AppGroupPaths,
        postSignal: (TunnelSignal) -> Void = TunnelSignal.post
    ) throws -> CompileStats {
        var stats = CompileStats()
        // First pair per hash wins, so iterating sources in state order makes
        // the first enabled source the attributed one.
        var blockEntries: [(hash: UInt64, source: UInt8)] = []
        var listAllowEntries: [(hash: UInt64, source: UInt8)] = []
        var blockHashes = Set<UInt64>()
        var listAllowHashes = Set<UInt64>()

        allocateSourceNumbers(state: &state)

        // A hidden source must not keep filtering from behind the curtain: a
        // relay list enabled before the UI was hidden is skipped, not compiled.
        for source in state.sources where source.enabled && !FeatureFlags.isHidden(sourceID: source.id) {
            let text: String
            if let bundled = SeedRules.bundledText(for: source.id) {
                text = bundled
            } else {
                let url = paths.cachedListURL(sourceID: source.id)
                guard let data = try? Data(contentsOf: url),
                      let cached = String(data: data, encoding: .utf8) else { continue }
                text = cached
            }

            let parsed = FilterListParser.parse(text)
            stats.skippedLines += parsed.skippedLines
            stats.perSourceCounts[source.id] = parsed.blockDomains.count
            var metadata = state.metadata[source.id] ?? FilterListMetadata()
            metadata.entryCount = parsed.blockDomains.count
            state.metadata[source.id] = metadata

            let number = state.sourceNumbers?[source.id] ?? 0
            for domain in parsed.blockDomains {
                let hash = FNV1a.hash64(domain)
                if blockHashes.insert(hash).inserted { blockEntries.append((hash, number)) }
            }
            for domain in parsed.allowDomains {
                let hash = FNV1a.hash64(domain)
                if listAllowHashes.insert(hash).inserted { listAllowEntries.append((hash, number)) }
            }
        }

        // List-level @@ exceptions are no longer subtracted here: they are
        // written to listallow.bin and applied at lookup time.

        let userAllowHashes = normalizeToHashes(state.userAllowlist)
        let userDenyHashes = normalizeToHashes(state.userDenylist)

        state.generation &+= 1
        state.compiledSeedVersion = SeedRules.version
        state.compiledFormatVersion = CompiledBlocklist.formatVersion
        let generation = state.generation

        // blocklist.bin goes last: the tunnel keys reloads off its generation,
        // so the exceptions and user blobs must already be on disk.
        try CompiledBlocklist.serialize(entries: listAllowEntries, generation: generation)
            .write(to: paths.listAllowlistURL, options: CompiledBlocklist.writingOptions)
        try CompiledBlocklist.write(hashes: userAllowHashes, generation: generation, to: paths.userAllowlistURL)
        try CompiledBlocklist.write(hashes: userDenyHashes, generation: generation, to: paths.userDenylistURL)
        try CompiledBlocklist.serialize(entries: blockEntries, generation: generation)
            .write(to: paths.blocklistURL, options: CompiledBlocklist.writingOptions)

        // Only after all four blobs are on disk, so the tunnel never reloads
        // a half-written set.
        postSignal(.blocklistChanged)

        stats.blockedEntryCount = blockHashes.count
        stats.listAllowEntryCount = listAllowHashes.count
        stats.userAllowEntryCount = userAllowHashes.count
        stats.userDenyEntryCount = userDenyHashes.count
        stats.generation = generation
        let numbered = state.sourceNumbers?.values.filter { $0 != 0 }.count ?? 0
        log.info("compiled v2: \(stats.blockedEntryCount) blocked, \(stats.listAllowEntryCount) list exceptions, \(numbered) sources numbered")
        return stats
    }

    /// Highest source number that can be allocated; 0 means "unknown".
    static let maxSourceNumber: UInt8 = 250

    private static let log = Log(category: "lists")

    /// Gives every source a stable number in 1...250. Entries are never
    /// pruned, so the number of a removed source stays reserved and is never
    /// handed to another source. When the range is exhausted the source is
    /// recorded as 0 (unknown) and keeps that value.
    static func allocateSourceNumbers(state: inout FilterListState) {
        var numbers = state.sourceNumbers ?? [:]
        var used = Set(numbers.values)
        used.remove(0)
        var next: UInt8 = 1
        var changed = state.sourceNumbers == nil

        for source in state.sources where numbers[source.id] == nil {
            while next <= maxSourceNumber, used.contains(next) { next += 1 }
            if next <= maxSourceNumber {
                numbers[source.id] = next
                used.insert(next)
            } else {
                numbers[source.id] = 0
                log.error("source numbers exhausted, \(source.id) recorded as unknown")
            }
            changed = true
        }
        if changed { state.sourceNumbers = numbers }
    }

    private static func normalizeToHashes(_ domains: [String]) -> Set<UInt64> {
        var hashes = Set<UInt64>()
        for raw in domains {
            if let domain = DomainValidator.normalize(raw) {
                hashes.insert(FNV1a.hash64(domain))
            }
        }
        return hashes
    }
}
