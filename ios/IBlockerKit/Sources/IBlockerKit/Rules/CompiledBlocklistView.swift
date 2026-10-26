import Foundation

/// Read-only, memory-mapped view over a compiled blocklist blob.
/// Lookups binary-search the file-backed pages directly, so resident memory
/// stays tiny regardless of list size.
public final class CompiledBlocklistView: Sendable {
    public enum ReadError: Error {
        case badMagic
        case unsupportedVersion
        case corrupt
    }

    private let data: Data
    public let count: Int
    public let generation: UInt32
    /// On-disk format version: 1 (hashes only) or 2 (hashes plus source numbers).
    public let formatVersion: UInt32

    public init(contentsOf url: URL) throws {
        let mapped = try Data(contentsOf: url, options: .alwaysMapped)
        guard mapped.count >= CompiledBlocklist.headerSize else { throw ReadError.corrupt }
        guard Array(mapped.prefix(4)) == CompiledBlocklist.magic else { throw ReadError.badMagic }

        let version = Self.readU32(mapped, at: 4)
        guard version == CompiledBlocklist.legacyFormatVersion || version == CompiledBlocklist.formatVersion else {
            throw ReadError.unsupportedVersion
        }

        let entryCount = Int(Self.readU32(mapped, at: 8))
        let entrySize = version == CompiledBlocklist.formatVersion ? 9 : 8
        guard mapped.count == CompiledBlocklist.headerSize + entryCount * entrySize else { throw ReadError.corrupt }

        self.data = mapped
        self.count = entryCount
        self.generation = Self.readU32(mapped, at: 12)
        self.formatVersion = version
    }

    public var isEmpty: Bool { count == 0 }

    public func contains(_ hash: UInt64) -> Bool {
        index(of: hash) != nil
    }

    /// Source number for a hash, or nil when absent. Always 0 for v1 blobs.
    public func sourceNumber(of hash: UInt64) -> UInt8? {
        lookup(hash)
    }

    /// Single binary search returning the source number of `hash`, or nil
    /// when absent. v1 blobs carry no source numbers, so present hashes report 0.
    public func lookup(_ hash: UInt64) -> UInt8? {
        guard let position = index(of: hash) else { return nil }
        guard formatVersion == CompiledBlocklist.formatVersion else { return 0 }
        let offset = CompiledBlocklist.headerSize + count * 8 + position
        return data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt8.self) }
    }

    private func index(of hash: UInt64) -> Int? {
        guard count > 0 else { return nil }
        return data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Int? in
            var low = 0
            var high = count - 1
            while low <= high {
                let mid = (low + high) / 2
                let offset = CompiledBlocklist.headerSize + mid * 8
                let value = UInt64(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
                if value == hash {
                    return mid
                } else if value < hash {
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }
            return nil
        }
    }

    private static func readU32(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { buffer in
            UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }
}
