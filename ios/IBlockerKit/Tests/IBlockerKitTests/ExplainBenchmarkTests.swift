import XCTest
@testable import IBlockerKit

/// Timing guard for `explain` over a large blob (spec: <= 1.2x with empty
/// exceptions, <= 2x with 10k exceptions, against the same lookup path).
final class ExplainBenchmarkTests: XCTestCase {

    private func names(_ count: Int, prefix: String) -> [String] {
        var rng = SeededGenerator(seed: 7)
        return (0..<count).map { _ in "\(prefix)\(rng.next() % 5_000_000).h\(rng.next() % 1000).example.com" }
    }

    private func time(_ body: () -> Int) -> (TimeInterval, Int) {
        let start = Date()
        let result = body()
        return (Date().timeIntervalSince(start), result)
    }

    func testExplainOverLargeBlob() throws {
        let dir = try makeTempDirectory()
        var rng = SeededGenerator(seed: 99)
        let blockHashes = (0..<400_000).map { _ in rng.next() }
        let blockURL = dir.appendingPathComponent("b.bin")
        try CompiledBlocklist.write(entries: blockHashes.map { (hash: $0, source: UInt8(1)) }, generation: 1, to: blockURL)
        let emptyURL = dir.appendingPathComponent("e0.bin")
        try writeV2Blob([], to: emptyURL)
        let tenKURL = dir.appendingPathComponent("e10k.bin")
        var exceptionRng = SeededGenerator(seed: 5)
        try CompiledBlocklist.write(entries: (0..<10_000).map { _ in (hash: exceptionRng.next(), source: UInt8(2)) },
                                    generation: 1, to: tenKURL)

        let block = try loadView(blockURL)
        let queries = names(100_000, prefix: "q")

        func run(_ matcher: DomainMatcher, explain: Bool) -> TimeInterval {
            // Best of 3 to damp scheduling noise.
            (0..<3).map { _ in
                time {
                    var blocked = 0
                    for q in queries {
                        if explain {
                            if matcher.explain(q).verdict == .block { blocked += 1 }
                        } else if matcher.hit(for: q) != nil { blocked += 1 }
                    }
                    return blocked
                }.0
            }.min()!
        }

        let baseline = run(DomainMatcher(blocklist: block, listAllowlist: try loadView(emptyURL)), explain: false)
        let emptyEx = run(DomainMatcher(blocklist: block, listAllowlist: try loadView(emptyURL)), explain: true)
        let tenK = run(DomainMatcher(blocklist: block, listAllowlist: try loadView(tenKURL)), explain: true)
        print("explain benchmark: baseline \(baseline)s, empty \(emptyEx)s, 10k \(tenK)s")

        // Explain on empty exceptions is the same walk as the baseline; allow a floor for tiny timings.
        XCTAssertLessThanOrEqual(emptyEx, max(baseline * 1.2, baseline + 0.05))
        XCTAssertLessThanOrEqual(tenK, max(baseline * 2.0, baseline + 0.05))
    }
}
