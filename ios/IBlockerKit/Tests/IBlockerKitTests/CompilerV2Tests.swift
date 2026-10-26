import XCTest
@testable import IBlockerKit

final class CompilerV2Tests: XCTestCase {

    private func makePaths() throws -> AppGroupPaths {
        let paths = AppGroupPaths(containerURL: try makeTempDirectory())
        try paths.ensureDirectories()
        return paths
    }

    private func source(_ id: String, enabled: Bool = true) -> FilterListSource {
        FilterListSource(id: id, name: id.uppercased(), url: URL(string: "https://example.com/\(id)")!,
                         enabled: enabled, isBuiltIn: false)
    }

    private func cache(_ paths: AppGroupPaths, _ id: String, _ text: String) throws {
        try text.write(to: paths.cachedListURL(sourceID: id), atomically: true, encoding: .utf8)
    }

    func testCompileWritesV2BlobsWithExceptionsAndAttribution() throws {
        let paths = try makePaths()
        var state = FilterListState(sources: [source("a"), source("b"), source("off", enabled: false)])
        state.userDenylist = ["mine.example.org"]
        try cache(paths, "a", "ads.example.com\nshared.example.net\n@@||safe.example.com^\n")
        try cache(paths, "b", "shared.example.net\nsafe.example.com\nonly-b.example.org\n@@||b-exc.example.org^\n")
        try cache(paths, "off", "disabled.example.com\n@@||disabled-exc.example.com^\n")

        let stats = try BlocklistCompiler.compile(state: &state, paths: paths)

        let block = try CompiledBlocklistView(contentsOf: paths.blocklistURL)
        let exceptions = try CompiledBlocklistView(contentsOf: paths.listAllowlistURL)
        XCTAssertEqual(block.formatVersion, 2)
        XCTAssertEqual(exceptions.formatVersion, 2)
        XCTAssertEqual(block.generation, exceptions.generation)
        XCTAssertEqual(block.generation, stats.generation)
        XCTAssertEqual(try CompiledBlocklistView(contentsOf: paths.userDenylistURL).formatVersion, 1)
        XCTAssertEqual(try CompiledBlocklistView(contentsOf: paths.userAllowlistURL).formatVersion, 1)
        XCTAssertEqual(state.compiledFormatVersion, 2)
        XCTAssertEqual(CompiledBlocklist.formatVersion, 2)

        let numA = try XCTUnwrap(state.sourceNumbers?["a"])
        let numB = try XCTUnwrap(state.sourceNumbers?["b"])
        XCTAssertNotEqual(numA, numB)

        // A hash in both blocklist and @@ stays in blocklist.bin and is also in listallow.bin.
        let safe = FNV1a.hash64("safe.example.com")
        XCTAssertNotNil(block.lookup(safe))
        XCTAssertEqual(exceptions.lookup(safe), numA)
        // Source attribution follows state.sources order (first wins).
        XCTAssertEqual(block.lookup(FNV1a.hash64("shared.example.net")), numA)
        XCTAssertEqual(block.lookup(FNV1a.hash64("only-b.example.org")), numB)
        XCTAssertEqual(block.lookup(FNV1a.hash64("ads.example.com")), numA)
        XCTAssertEqual(exceptions.lookup(FNV1a.hash64("b-exc.example.org")), numB)
        // Disabled sources are excluded.
        XCTAssertNil(block.lookup(FNV1a.hash64("disabled.example.com")))
        XCTAssertNil(exceptions.lookup(FNV1a.hash64("disabled-exc.example.com")))

        XCTAssertEqual(stats.listAllowEntryCount, 2)
        XCTAssertEqual(stats.blockedEntryCount, block.count)

        let matcher = paths.loadMatcher()
        XCTAssertEqual(matcher.verdict(for: "safe.example.com"), .allow)
        XCTAssertEqual(matcher.verdict(for: "sub.safe.example.com"), .allow)
        XCTAssertEqual(matcher.verdict(for: "ads.example.com"), .block)
        XCTAssertEqual(matcher.verdict(for: "mine.example.org"), .block)
    }

    func testBlocklistIsWrittenLastAndSignalFollowsAllWrites() throws {
        let paths = try makePaths()
        var state = FilterListState(sources: [source("a")])
        try cache(paths, "a", "ads.example.com\n")
        // Block the blocklist write; the other blobs must already be on disk with the new generation.
        try FileManager.default.createDirectory(at: paths.blocklistURL.appendingPathComponent("x"),
                                                withIntermediateDirectories: true)
        var posted = 0
        XCTAssertThrowsError(try BlocklistCompiler.compile(state: &state, paths: paths) { _ in posted += 1 })
        XCTAssertEqual(posted, 0)
        XCTAssertEqual(try CompiledBlocklistView(contentsOf: paths.listAllowlistURL).generation, 1)
        XCTAssertEqual(try CompiledBlocklistView(contentsOf: paths.userAllowlistURL).generation, 1)
        XCTAssertEqual(try CompiledBlocklistView(contentsOf: paths.userDenylistURL).generation, 1)
    }

    // MARK: source numbers

    func testSourceNumbersAreStableAcrossCompiles() throws {
        let paths = try makePaths()
        var state = FilterListState(sources: [source("a"), source("b")])
        try BlocklistCompiler.compile(state: &state, paths: paths)
        let first = state.sourceNumbers
        try BlocklistCompiler.compile(state: &state, paths: paths)
        XCTAssertEqual(state.sourceNumbers, first)
        XCTAssertEqual(Set(first?.values.map { $0 } ?? []), [1, 2])
    }

    func testRemovedSourceNumberIsNeverReused() {
        var state = FilterListState(sources: [source("a"), source("b")])
        BlocklistCompiler.allocateSourceNumbers(state: &state)
        let removed = state.sourceNumbers?["b"]
        state.sources.removeAll { $0.id == "b" }
        state.sources.append(source("c"))
        BlocklistCompiler.allocateSourceNumbers(state: &state)
        XCTAssertNotNil(state.sourceNumbers?["c"])
        XCTAssertNotEqual(state.sourceNumbers?["c"], removed)
        XCTAssertEqual(state.sourceNumbers?["b"], removed, "entries are never pruned")
    }

    func testNumberExhaustionRecordsZeroAndKeepsIt() {
        var numbers: [String: UInt8] = [:]
        for i in 1...250 { numbers["used\(i)"] = UInt8(i) }
        var state = FilterListState(sources: [source("extra")], sourceNumbers: numbers)
        BlocklistCompiler.allocateSourceNumbers(state: &state)
        XCTAssertEqual(state.sourceNumbers?["extra"], 0)
        let before = state.sourceNumbers
        BlocklistCompiler.allocateSourceNumbers(state: &state)
        XCTAssertEqual(state.sourceNumbers, before)
        XCTAssertEqual(state.sourceNumbers?["extra"], 0)
    }

    func testNilSourceNumbersBecomeDictionary() {
        var state = FilterListState(sources: [])
        XCTAssertNil(state.sourceNumbers)
        BlocklistCompiler.allocateSourceNumbers(state: &state)
        XCTAssertEqual(state.sourceNumbers, [:])
    }

    // MARK: upgrade from v1

    func testCompileUpgradesLegacyV1State() throws {
        let paths = try makePaths()
        var state = FilterListState(sources: [source("a")], generation: 7, compiledSeedVersion: SeedRules.version)
        try cache(paths, "a", "ads.example.com\n@@||ok.example.com^\n")
        try writeV1Blob(["ads.example.com"], generation: 7, to: paths.blocklistURL)
        XCTAssertNil(state.compiledFormatVersion)

        try BlocklistCompiler.compile(state: &state, paths: paths)

        XCTAssertEqual(state.compiledFormatVersion, 2)
        XCTAssertEqual(try CompiledBlocklistView(contentsOf: paths.blocklistURL).formatVersion, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.listAllowlistURL.path))
        XCTAssertEqual(state.generation, 8)
    }
}
