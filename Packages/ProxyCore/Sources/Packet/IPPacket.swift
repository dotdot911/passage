import Foundation

/// A parsed view of one IPv4 or IPv6 packet from the tunnel.
public struct IPPacket: Sendable {
    public enum Proto: UInt8, Sendable { case icmp = 1, tcp = 6, udp = 17, icmpv6 = 58 }

    public let bytes: [UInt8]
    public let version: Int
    /// Raw protocol number (IPv6: the Next Header of the fixed header; extension headers are not walked).
    public let protocolNumber: UInt8
    public let source: [UInt8]
    public let destination: [UInt8]
    /// Offset of the transport header.
    public let payloadOffset: Int

    public var proto: Proto? { Proto(rawValue: protocolNumber) }

    public init?(_ data: Data) { self.init(bytes: [UInt8](data)) }

    public init?(bytes b: [UInt8]) {
        guard let first = b.first else { return nil }
        switch first >> 4 {
        case 4:
            guard b.count >= 20 else { return nil }
            let ihl = Int(first & 0x0f) * 4
            let total = Int(b[2]) << 8 | Int(b[3])
            guard ihl >= 20, b.count >= ihl, total <= b.count else { return nil }
            // Fragments other than the first carry no transport header: treat as unparseable.
            let fragOffset = (Int(b[6] & 0x1f) << 8) | Int(b[7])
            guard fragOffset == 0 else { return nil }
            self.bytes = Array(b[0..<total])
            self.version = 4
            self.protocolNumber = b[9]
            self.source = Array(b[12..<16])
            self.destination = Array(b[16..<20])
            self.payloadOffset = ihl
        case 6:
            guard b.count >= 40 else { return nil }
            let payloadLen = Int(b[4]) << 8 | Int(b[5])
            guard 40 + payloadLen <= b.count else { return nil }
            self.bytes = Array(b[0..<(40 + payloadLen)])
            self.version = 6
            self.protocolNumber = b[6]
            self.source = Array(b[8..<24])
            self.destination = Array(b[24..<40])
            self.payloadOffset = 40
        default:
            return nil
        }
    }

    /// UDP header + payload, if this is a well-formed UDP packet.
    public var udp: UDPDatagram? {
        guard proto == .udp, bytes.count >= payloadOffset + 8 else { return nil }
        let o = payloadOffset
        let len = Int(bytes[o + 4]) << 8 | Int(bytes[o + 5])
        guard len >= 8, o + len <= bytes.count else { return nil }
        return UDPDatagram(sourcePort: UInt16(bytes[o]) << 8 | UInt16(bytes[o + 1]),
                           destinationPort: UInt16(bytes[o + 2]) << 8 | UInt16(bytes[o + 3]),
                           payload: Array(bytes[(o + 8)..<(o + len)]))
    }
}

public struct UDPDatagram: Equatable, Sendable {
    public var sourcePort: UInt16
    public var destinationPort: UInt16
    public var payload: [UInt8]
    public init(sourcePort: UInt16, destinationPort: UInt16, payload: [UInt8]) {
        self.sourcePort = sourcePort; self.destinationPort = destinationPort; self.payload = payload
    }
}
