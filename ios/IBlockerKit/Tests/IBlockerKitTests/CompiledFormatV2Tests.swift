import XCTest
@testable import IBlockerKit

/// Blob helpers shared by the matcher, compiler and engine tests.
func writeV1Blob(_ domains: [String], generation: UInt32 = 1, to url: URL) throws {
    try CompiledBlocklist.write(hashes: domains.map { FNV1a.hash64($0) }, generation: generation, to: url)
}

func writeV2Blob(_ entries: [(String, UInt8)], generation: UInt32 = 1, to url: URL) throws {
    try CompiledBlocklist.write(entries: entries.map { (hash: FNV1a.hash64($0.0), source: $0.1) },
                                generation: generation, to: url)
}

func loadView(_ url: URL) throws -> CompiledBlocklistView {
    try CompiledBlocklistView(contentsOf: url)
}

final class CompiledFormatV2Tests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = try makeTempDirectory()
    }

    private func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    func testV2SizeVersionAndOrdering() {
        let entries: [(hash: UInt64, source: UInt8)] = [(30, 3), (10, 1), (20, 2)]
        let data = CompiledBlocklist.serialize(entries: entries, generation: 5)
        XCTAssertEqual(data.count, 32 + 3 * 9)
        XCTAssertEqual(Array(data.prefix(4)), CompiledBlocklist.magic)
        XCTAssertEqual(u32(data, 4), 2)
        XCTAssertEqual(u32(data, 8), 3)
        XCTAssertEqual(u32(data, 12), 5)
        let hashes = (0..<3).map { i in
            data.subdata(in: (32 + i * 8)..<(40 + i * 8)).withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
        }
        XCTAssertEqual(hashes, [10, 20, 30])
        XCTAssertEqual(Array(data[(32 + 24)...]), [1, 2, 3])
    }

    func testV2DuplicateHashKeepsFirstSource() {
        let data = CompiledBlocklist.serialize(entries: [(hash: 7, source: 4), (hash: 7, source: 9)], generation: 1)
        XCTAssertEqual(data.count, 32 + 9)
        XCTAssertEqual(data.last, 4)
    }

    func testEmptyV2BlobIs32Bytes() throws {
        let data = CompiledBlocklist.serialize(entries: [(hash: UInt64, source: UInt8)](), generation: 1)
        XCTAssertEqual(data.count, 32)
        try data.write(to: url("e2.bin"))
        let view = try loadView(url("e2.bin"))
        XCTAssertTrue(view.isEmpty)
        XCTAssertEqual(view.formatVersion, 2)
    }

    func testV1SerializeStillVersion1() {
        let data = CompiledBlocklist.serialize(hashes: [UInt64(3), 1, 2], generation: 9)
        XCTAssertEqual(u32(data, 4), 1)
        XCTAssertEqual(data.count, 32 + 3 * 8)
    }

    func testV1LookupReturnsZeroForPresentNilForAbsent() throws {
        try writeV1Blob(["a.example.com"], to: url("v1.bin"))
        let view = try loadView(url("v1.bin"))
        XCTAssertEqual(view.formatVersion, 1)
        XCTAssertEqual(view.lookup(FNV1a.hash64("a.example.com")), 0)
        XCTAssertNil(view.lookup(FNV1a.hash64("b.example.com")))
        XCTAssertTrue(view.contains(FNV1a.hash64("a.example.com")))
        XCTAssertFalse(view.contains(FNV1a.hash64("b.example.com")))
    }

    func testV2RoundTripIncludingFirstAndLastEntries() throws {
        let names = (0..<200).map { "host\($0).example.com" }
        let entries = names.enumerated().map { ($0.element, UInt8($0.offset % 250 + 1)) }
        try writeV2Blob(entries, generation: 3, to: url("v2.bin"))
        let view = try loadView(url("v2.bin"))
        XCTAssertEqual(view.count, 200)
        XCTAssertEqual(view.generation, 3)
        XCTAssertEqual(view.formatVersion, 2)
        for (name, number) in entries {
            XCTAssertEqual(view.lookup(FNV1a.hash64(name)), number, name)
            XCTAssertEqual(view.sourceNumber(of: FNV1a.hash64(name)), number)
        }
        // Explicit first and last by hash order.
        let sorted = entries.map { FNV1a.hash64($0.0) }.sorted()
        XCTAssertNotNil(view.lookup(sorted.first!))
        XCTAssertNotNil(view.lookup(sorted.last!))
        XCTAssertNil(view.lookup(1))
    }

    func testEmptyV1BlobLoads() throws {
        try writeV1Blob([], to: url("e1.bin"))
        let view = try loadView(url("e1.bin"))
        XCTAssertTrue(view.isEmpty)
        XCTAssertEqual(view.formatVersion, 1)
        XCTAssertNil(view.lookup(5))
    }

    func testTruncatedAndTrailingBytesAreCorruptForBothVersions() throws {
        let v1 = CompiledBlocklist.serialize(hashes: [UInt64(1), 2], generation: 1)
        let v2 = CompiledBlocklist.serialize(entries: [(hash: UInt64(1), source: UInt8(1)), (hash: 2, source: 2)], generation: 1)
        for (label, blob) in [("v1", v1), ("v2", v2)] {
            try assertReadError(.corrupt, blob.dropLast(), "\(label) truncated")
            try assertReadError(.corrupt, blob + Data([0]), "\(label) trailing")
        }
        // v2 header with v1-sized body is also corrupt.
        var mismatched = v1
        mismatched.replaceSubrange(4..<8, with: Data([2, 0, 0, 0]))
        try assertReadError(.corrupt, mismatched, "v2 header, v1 body")
    }

    func testUnsupportedVersionsAndBadMagic() throws {
        for version: UInt8 in [0, 3] {
            var blob = CompiledBlocklist.serialize(hashes: [UInt64](), generation: 1)
            blob[4] = version
            try assertReadError(.unsupportedVersion, blob, "version \(version)")
        }
        var bad = CompiledBlocklist.serialize(hashes: [UInt64](), generation: 1)
        bad[0] = 0x58
        try assertReadError(.badMagic, bad, "magic")
    }

    private func assertReadError(_ expected: CompiledBlocklistView.ReadError, _ data: some DataProtocol,
                                 _ label: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let target = url("bad-\(UUID().uuidString).bin")
        try Data(data).write(to: target)
        XCTAssertThrowsError(try CompiledBlocklistView(contentsOf: target), label, file: file, line: line) { error in
            guard let read = error as? CompiledBlocklistView.ReadError else {
                return XCTFail("\(label): wrong error \(error)", file: file, line: line)
            }
            XCTAssertEqual(String(describing: read), String(describing: expected), label, file: file, line: line)
        }
    }

    private func u32(_ data: Data, _ at: Int) -> UInt32 {
        data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: at, as: UInt32.self)) }
    }
}

// MARK: - FilterListState new fields

final class FilterListStateFieldsTests: XCTestCase {
    func testLegacyJSONDecodesWithNilFields() throws {
        let json = #"{"sources":[],"metadata":{},"userAllowlist":[],"userDenylist":[],"generation":3}"#
        let state = try JSONDecoder().decode(FilterListState.self, from: Data(json.utf8))
        XCTAssertNil(state.sourceNumbers)
        XCTAssertNil(state.compiledFormatVersion)
    }

    func testRoundTripWithFieldsSet() throws {
        var state = FilterListState(sources: [])
        state.sourceNumbers = ["a": 1, "b": 250]
        state.compiledFormatVersion = 2
        let decoded = try JSONDecoder().decode(FilterListState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)
        XCTAssertEqual(decoded.sourceNumbers?["b"], 250)
    }
}
