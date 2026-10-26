import Foundation

/// The compiled on-disk blocklist format shared between the app (writer) and
/// the tunnel extension (reader). Designed to be mmap'd: the tunnel never
/// materializes the domain set in its 50 MB memory budget.
///
///     offset 0   magic "IBK1"                    (4 bytes)
///     offset 4   format version, u32 LE          (= 1 or 2)
///     offset 8   entry count, u32 LE
///     offset 12  generation, u32 LE              (monotonic, for change detection)
///     offset 16  reserved, 16 zero bytes
///     offset 32  count × u64 LE FNV-1a hashes, ascending
///     then       count × u8 source numbers, same order as the hashes   (v2 only)
///
/// Version 1 (user allow/deny blobs) has no source numbers; version 2 (the
/// blocklist and list exceptions) appends one per hash.
public enum CompiledBlocklist {
    public static let magic: [UInt8] = Array("IBK1".utf8)
    /// Current format version, written for blobs that carry source numbers.
    public static let formatVersion: UInt32 = 2
    /// Legacy format without source numbers, still written for user allow/deny blobs.
    public static let legacyFormatVersion: UInt32 = 1
    public static let headerSize = 32

    public static func serialize(hashes: some Collection<UInt64>, generation: UInt32) -> Data {
        let sorted = Array(Set(hashes)).sorted()
        var data = Data(capacity: headerSize + sorted.count * 8)
        data.append(contentsOf: magic)
        appendU32(&data, legacyFormatVersion)
        appendU32(&data, UInt32(sorted.count))
        appendU32(&data, generation)
        data.append(contentsOf: [UInt8](repeating: 0, count: 16))
        for hash in sorted {
            var le = hash.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Serializes a v2 blob from hash/source pairs. Sources are resolved by the
    /// caller; if a hash appears more than once, the first pair supplied wins.
    public static func serialize(entries: some Sequence<(hash: UInt64, source: UInt8)>, generation: UInt32) -> Data {
        var byHash: [UInt64: UInt8] = [:]
        for entry in entries where byHash[entry.hash] == nil {
            byHash[entry.hash] = entry.source
        }
        let sorted = byHash.keys.sorted()
        var data = Data(capacity: headerSize + sorted.count * 9)
        data.append(contentsOf: magic)
        appendU32(&data, formatVersion)
        appendU32(&data, UInt32(sorted.count))
        appendU32(&data, generation)
        data.append(contentsOf: [UInt8](repeating: 0, count: 16))
        for hash in sorted {
            var le = hash.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        for hash in sorted {
            data.append(byHash[hash] ?? 0)
        }
        return data
    }

    /// Options used to write the blobs: atomic so the tunnel never sees a
    /// half-written file, and (on Apple platforms) without data protection so
    /// the tunnel, which iOS can start before the first unlock, can read them.
    /// The blobs hold only 64-bit hashes, never readable domains.
    public static var writingOptions: Data.WritingOptions {
        return [.atomic, .noFileProtection]
    }

    /// Atomically writes the compiled blob so the tunnel never sees a
    /// half-written file.
    public static func write(hashes: some Collection<UInt64>, generation: UInt32, to url: URL) throws {
        let data = serialize(hashes: hashes, generation: generation)
        try data.write(to: url, options: writingOptions)
    }

    /// Atomically writes a v2 blob with per-hash source numbers.
    public static func write(entries: some Sequence<(hash: UInt64, source: UInt8)>, generation: UInt32, to url: URL) throws {
        let data = serialize(entries: entries, generation: generation)
        try data.write(to: url, options: writingOptions)
    }

    private static func appendU32(_ data: inout Data, _ value: UInt32) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
}
