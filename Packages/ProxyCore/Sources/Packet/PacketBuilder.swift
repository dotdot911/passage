/// Builds the packets the tunnel writes back that lwIP does not produce: UDP replies and ICMP errors.
public enum PacketBuilder {
    /// A UDP packet from `source:sourcePort` to `destination:destinationPort`. Address sizes pick IPv4/IPv6.
    public static func udp(source: [UInt8], sourcePort: UInt16, destination: [UInt8], destinationPort: UInt16,
                           payload: [UInt8]) -> [UInt8] {
        var udp = be16(sourcePort) + be16(destinationPort) + be16(UInt16(8 + payload.count)) + [0, 0] + payload
        var sum = pseudoHeaderSum(source: source, destination: destination, proto: 17, length: udp.count)
        sum = add(sum, udp)
        var c = finish(sum)
        if c == 0 { c = 0xffff } // RFC 768: zero means "no checksum"
        udp[6] = UInt8(c >> 8); udp[7] = UInt8(c & 0xff)
        return ipHeader(source: source, destination: destination, proto: 17, payloadLength: udp.count) + udp
    }

    /// ICMP "port unreachable" for `original` (makes QUIC clients fall back to TCP immediately).
    public static func portUnreachable(for original: IPPacket) -> [UInt8] {
        if original.version == 4 {
            let quoted = Array(original.bytes.prefix(original.payloadOffset + 8))
            var icmp: [UInt8] = [3, 3, 0, 0, 0, 0, 0, 0] + quoted
            let c = finish(add(0, icmp))
            icmp[2] = UInt8(c >> 8); icmp[3] = UInt8(c & 0xff)
            return ipHeader(source: original.destination, destination: original.source, proto: 1, payloadLength: icmp.count) + icmp
        } else {
            let quoted = Array(original.bytes.prefix(1280 - 40 - 8))
            var icmp: [UInt8] = [1, 4, 0, 0, 0, 0, 0, 0] + quoted
            let sum = add(pseudoHeaderSum(source: original.destination, destination: original.source, proto: 58, length: icmp.count), icmp)
            let c = finish(sum)
            icmp[2] = UInt8(c >> 8); icmp[3] = UInt8(c & 0xff)
            return ipHeader(source: original.destination, destination: original.source, proto: 58, payloadLength: icmp.count) + icmp
        }
    }

    // MARK: Internals

    static func ipHeader(source: [UInt8], destination: [UInt8], proto: UInt8, payloadLength: Int) -> [UInt8] {
        if source.count == 4 {
            var h: [UInt8] = [0x45, 0] + be16(UInt16(20 + payloadLength)) + [0, 0, 0x40, 0, 64, proto, 0, 0] + source + destination
            let c = finish(add(0, h))
            h[10] = UInt8(c >> 8); h[11] = UInt8(c & 0xff)
            return h
        }
        return [0x60, 0, 0, 0] + be16(UInt16(payloadLength)) + [proto, 64] + source + destination
    }

    static func pseudoHeaderSum(source: [UInt8], destination: [UInt8], proto: UInt8, length: Int) -> UInt32 {
        var sum = add(0, source)
        sum = add(sum, destination)
        if source.count == 4 {
            sum = add(sum, [0, proto] + be16(UInt16(length)))
        } else {
            sum = add(sum, be32(UInt32(length)) + [0, 0, 0, proto])
        }
        return sum
    }

    /// One's-complement sum of 16-bit words (odd trailing byte padded with zero).
    static func add(_ initial: UInt32, _ bytes: [UInt8]) -> UInt32 {
        var sum = initial
        var i = 0
        while i + 1 < bytes.count {
            sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
            i += 2
        }
        if i < bytes.count { sum += UInt32(bytes[i]) << 8 }
        return sum
    }

    static func finish(_ s: UInt32) -> UInt16 {
        var sum = s
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum)
    }

    static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }
    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
}
