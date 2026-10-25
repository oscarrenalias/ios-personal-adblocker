import Foundation

/// Builds the raw IP reply packet for a request that arrived through the
/// tunnel: the 5-tuple is swapped and checksums are computed from scratch.
public enum UDPReplyBuilder {

    public static func reply(to request: ParsedUDPPacket, payload: [UInt8]) -> Data? {
        switch request.ipVersion {
        case 4: return ipv4Reply(to: request, payload: payload)
        case 6: return ipv6Reply(to: request, payload: payload)
        default: return nil
        }
    }

    /// Largest UDP payload that fits a datagram of the IP version's maximum
    /// size (65,535 bytes IPv4 including the header; 65,535 payload IPv6).
    public static func maxPayload(ipVersion: Int) -> Int {
        ipVersion == 4 ? 65_507 : 65_527
    }

    /// Builds the reply as one or more IP packets, each at most `mtu` bytes.
    /// A reply that fits is a single packet identical to `reply(to:payload:)`;
    /// larger ones are IP-fragmented (RFC 791 / RFC 8200). Returns an empty
    /// array when the payload exceeds `maxPayload(ipVersion:)` or the request
    /// is malformed.
    public static func replyPackets(to request: ParsedUDPPacket, payload: [UInt8], mtu: Int,
                                    identification: UInt32 = UInt32.random(in: 1...UInt32.max)) -> [Data] {
        let ipHeader = request.ipVersion == 4 ? 20 : 40
        guard request.ipVersion == 4 || request.ipVersion == 6,
              payload.count <= maxPayload(ipVersion: request.ipVersion),
              request.sourceAddress.count == (request.ipVersion == 4 ? 4 : 16),
              request.destinationAddress.count == request.sourceAddress.count else { return [] }

        if ipHeader + 8 + payload.count <= mtu {
            return reply(to: request, payload: payload).map { [$0] } ?? []
        }

        let fragmentHeader = request.ipVersion == 4 ? 0 : 8
        let chunk = ((mtu - ipHeader - fragmentHeader) / 8) * 8
        guard chunk > 0 else { return [] }

        let segment = udpSegment(
            sourcePort: request.destinationPort,
            destinationPort: request.sourcePort,
            payload: payload,
            ipVersion: request.ipVersion,
            sourceAddress: request.destinationAddress,
            destinationAddress: request.sourceAddress
        )

        var packets: [Data] = []
        var offset = 0
        while offset < segment.count {
            let end = min(offset + chunk, segment.count)
            let more = end < segment.count
            let slice = Array(segment[offset..<end])
            if request.ipVersion == 4 {
                var id = UInt16(truncatingIfNeeded: identification)
                if id == 0 { id = 1 }
                let total = 20 + slice.count
                let fragField = UInt16(offset / 8) | (more ? 0x2000 : 0)
                var header: [UInt8] = [
                    0x45, 0x00,
                    UInt8(total >> 8), UInt8(total & 0xFF),
                    UInt8(id >> 8), UInt8(id & 0xFF),
                    UInt8(fragField >> 8), UInt8(fragField & 0xFF),   // no DF
                    64, 17,
                    0x00, 0x00,
                ]
                header.append(contentsOf: request.destinationAddress)
                header.append(contentsOf: request.sourceAddress)
                let checksum = InternetChecksum.ipv4Header(header)
                header[10] = UInt8(checksum >> 8)
                header[11] = UInt8(checksum & 0xFF)
                packets.append(Data(header + slice))
            } else {
                let payloadLength = 8 + slice.count
                var header: [UInt8] = [
                    0x60, 0x00, 0x00, 0x00,
                    UInt8(payloadLength >> 8), UInt8(payloadLength & 0xFF),
                    44, 64,                 // next header: Fragment, hop limit
                ]
                header.append(contentsOf: request.destinationAddress)
                header.append(contentsOf: request.sourceAddress)
                let fragField = UInt16(offset / 8) << 3 | (more ? 1 : 0)
                header.append(contentsOf: [
                    17, 0,                  // next header UDP, reserved
                    UInt8(fragField >> 8), UInt8(fragField & 0xFF),
                    UInt8(identification >> 24), UInt8((identification >> 16) & 0xFF),
                    UInt8((identification >> 8) & 0xFF), UInt8(identification & 0xFF),
                ])
                packets.append(Data(header + slice))
            }
            offset = end
        }
        return packets
    }

    private static func ipv4Reply(to request: ParsedUDPPacket, payload: [UInt8]) -> Data? {
        let udpLength = 8 + payload.count
        let totalLength = 20 + udpLength
        guard totalLength <= 0xFFFF,
              request.sourceAddress.count == 4,
              request.destinationAddress.count == 4 else { return nil }

        var header: [UInt8] = [
            0x45, 0x00,
            UInt8(totalLength >> 8), UInt8(totalLength & 0xFF),
            0x00, 0x00,             // identification (DF set, so 0 is valid per RFC 6864)
            0x40, 0x00,             // flags: DF
            64, 17,                 // TTL, protocol UDP
            0x00, 0x00,             // header checksum (placeholder)
        ]
        header.append(contentsOf: request.destinationAddress)  // our reply source
        header.append(contentsOf: request.sourceAddress)       // back to the client

        let headerChecksum = InternetChecksum.ipv4Header(header)
        header[10] = UInt8(headerChecksum >> 8)
        header[11] = UInt8(headerChecksum & 0xFF)

        let segment = udpSegment(
            sourcePort: request.destinationPort,
            destinationPort: request.sourcePort,
            payload: payload,
            ipVersion: 4,
            sourceAddress: request.destinationAddress,
            destinationAddress: request.sourceAddress
        )

        return Data(header + segment)
    }

    private static func ipv6Reply(to request: ParsedUDPPacket, payload: [UInt8]) -> Data? {
        let udpLength = 8 + payload.count
        guard udpLength <= 0xFFFF,
              request.sourceAddress.count == 16,
              request.destinationAddress.count == 16 else { return nil }

        var header: [UInt8] = [
            0x60, 0x00, 0x00, 0x00,
            UInt8(udpLength >> 8), UInt8(udpLength & 0xFF),
            17, 64,                 // next header UDP, hop limit
        ]
        header.append(contentsOf: request.destinationAddress)
        header.append(contentsOf: request.sourceAddress)

        let segment = udpSegment(
            sourcePort: request.destinationPort,
            destinationPort: request.sourcePort,
            payload: payload,
            ipVersion: 6,
            sourceAddress: request.destinationAddress,
            destinationAddress: request.sourceAddress
        )

        return Data(header + segment)
    }

    private static func udpSegment(sourcePort: UInt16, destinationPort: UInt16, payload: [UInt8],
                                   ipVersion: Int, sourceAddress: [UInt8], destinationAddress: [UInt8]) -> [UInt8] {
        let udpLength = 8 + payload.count
        var segment: [UInt8] = [
            UInt8(sourcePort >> 8), UInt8(sourcePort & 0xFF),
            UInt8(destinationPort >> 8), UInt8(destinationPort & 0xFF),
            UInt8(udpLength >> 8), UInt8(udpLength & 0xFF),
            0x00, 0x00,             // checksum (placeholder)
        ]
        segment.append(contentsOf: payload)

        let checksum = InternetChecksum.udp(
            ipVersion: ipVersion,
            source: sourceAddress,
            destination: destinationAddress,
            segment: segment
        )
        segment[6] = UInt8(checksum >> 8)
        segment[7] = UInt8(checksum & 0xFF)
        return segment
    }
}
