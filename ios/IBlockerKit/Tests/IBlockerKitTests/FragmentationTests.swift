import XCTest
@testable import IBlockerKit

struct ReassembledDatagram {
    var ipVersion: Int
    var source: [UInt8]
    var destination: [UInt8]
    var segment: [UInt8]      // UDP header + payload
    var payload: [UInt8] { Array(segment.dropFirst(8)) }
    var checksumValid: Bool {
        InternetChecksum.udp(ipVersion: ipVersion, source: source, destination: destination,
                             segment: Array(segment[0..<6]) + [0, 0] + segment[8...])
            == (UInt16(segment[6]) << 8 | UInt16(segment[7]))
    }
}

/// Reassembles IPv4/IPv6 fragments (any order) into the UDP datagram,
/// validating IPv4 header checksums and fragment flags on the way.
func reassemble(_ packets: [Data]) -> ReassembledDatagram? {
    guard let first = packets.first?.first else { return nil }
    let version = Int(first >> 4)
    var pieces: [(offset: Int, more: Bool, data: [UInt8])] = []
    var source: [UInt8] = [], destination: [UInt8] = []
    var ident: [UInt8]?
    for p in packets {
        let b = [UInt8](p)
        if version == 4 {
            guard b[0] == 0x45, InternetChecksum.finalize(InternetChecksum.sum16(Array(b[0..<20]))) == 0 else { return nil }
            let flagsOffset = Int(b[6]) << 8 | Int(b[7])
            guard flagsOffset & 0x4000 == 0 else { return nil }  // DF must be clear
            let id = Array(b[4..<6])
            if let ident, ident != id || id == [0, 0] { return nil }
            ident = id
            source = Array(b[12..<16]); destination = Array(b[16..<20])
            pieces.append(((flagsOffset & 0x1FFF) * 8, flagsOffset & 0x2000 != 0, Array(b[20...])))
        } else {
            guard b[6] == 44, b[40] == 17 else { return nil }
            let id = Array(b[44..<48])
            if let ident, ident != id { return nil }
            ident = id
            source = Array(b[8..<24]); destination = Array(b[24..<40])
            let field = Int(b[42]) << 8 | Int(b[43])
            pieces.append(((field >> 3) * 8, field & 1 != 0, Array(b[48...])))
        }
    }
    pieces.sort { $0.offset < $1.offset }
    var segment: [UInt8] = []
    for (i, piece) in pieces.enumerated() {
        guard piece.offset == segment.count, piece.more == (i < pieces.count - 1) else { return nil }
        if piece.more { guard piece.data.count % 8 == 0 else { return nil } }
        segment += piece.data
    }
    return ReassembledDatagram(ipVersion: version, source: source, destination: destination, segment: segment)
}

final class FragmentationTests: XCTestCase {
    private func answer(_ n: Int) -> [UInt8] { (0..<n).map { UInt8(truncatingIfNeeded: $0 &* 7) } }

    func testIPv4LargeReplyFragments() throws {
        let request = try XCTUnwrap(PacketParser.parseUDP(makeUDPPacketV4(payload: [UInt8](makeDNSQueryData(name: "a.example.com")))))
        let payload = answer(3000)
        let packets = UDPReplyBuilder.replyPackets(to: request, payload: payload, mtu: 1500)
        XCTAssertGreaterThanOrEqual(packets.count, 3)
        XCTAssertTrue(packets.allSatisfy { $0.count <= 1500 })
        let datagram = try XCTUnwrap(reassemble(packets.reversed()))
        XCTAssertEqual(datagram.payload, payload)
        XCTAssertTrue(datagram.checksumValid)
        XCTAssertEqual(datagram.source, request.destinationAddress)
    }

    func testIPv6LargeReplyFragments() throws {
        let request = try XCTUnwrap(PacketParser.parseUDP(makeUDPPacketV6(payload: [UInt8](makeDNSQueryData(name: "a.example.com")))))
        let payload = answer(3000)
        let packets = UDPReplyBuilder.replyPackets(to: request, payload: payload, mtu: 1500)
        XCTAssertGreaterThanOrEqual(packets.count, 3)
        XCTAssertTrue(packets.allSatisfy { $0.count <= 1500 && $0[6] == 44 })
        let datagram = try XCTUnwrap(reassemble(packets))
        XCTAssertEqual(datagram.payload, payload)
        XCTAssertTrue(datagram.checksumValid)
    }

    func testSmallReplyIsSinglePacketIdenticalToReply() throws {
        for packet in [makeUDPPacketV4(payload: [1, 2, 3]), makeUDPPacketV6(payload: [1, 2, 3])] {
            let request = try XCTUnwrap(PacketParser.parseUDP(packet))
            let payload = answer(1000)
            let packets = UDPReplyBuilder.replyPackets(to: request, payload: payload, mtu: 1500)
            XCTAssertEqual(packets, [try XCTUnwrap(UDPReplyBuilder.reply(to: request, payload: payload))])
        }
    }

    func testPayloadAboveMaxYieldsNoPackets() throws {
        let v4 = try XCTUnwrap(PacketParser.parseUDP(makeUDPPacketV4(payload: [1])))
        XCTAssertTrue(UDPReplyBuilder.replyPackets(to: v4, payload: answer(65_508), mtu: 1500).isEmpty)
        XCTAssertFalse(UDPReplyBuilder.replyPackets(to: v4, payload: answer(65_507), mtu: 1500).isEmpty)
    }
}
