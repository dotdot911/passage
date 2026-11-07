import Foundation

/// Builds minimal IPv4/TCP packets. Checksums are left zero: lwIP is built with
/// CHECKSUM_CHECK_IP/TCP = 0 because the OS already validated tunnel packets.
public enum PacketFixtures {
    public static let client: [UInt8] = [198, 18, 0, 2]
    public static let server: [UInt8] = [93, 184, 216, 34]

    public static func tcp4(src: [UInt8] = client, srcPort: UInt16 = 50000,
                     dst: [UInt8] = server, dstPort: UInt16 = 443,
                     seq: UInt32, ack: UInt32 = 0, flags: UInt8,
                     payload: [UInt8] = []) -> Data {
        var tcp: [UInt8] = []
        tcp += be16(srcPort) + be16(dstPort) + be32(seq) + be32(ack)
        tcp += [0x50, flags] + be16(65535) + [0, 0, 0, 0]
        tcp += payload
        let total = 20 + tcp.count
        var ip: [UInt8] = [0x45, 0] + be16(UInt16(total)) + [0, 1, 0x40, 0, 64, 6, 0, 0]
        ip += src + dst
        return Data(ip + tcp)
    }

    /// Parses the TCP header of an IPv4 packet emitted by lwIP.
    public static func parseTCP4(_ d: Data) -> (srcPort: UInt16, dstPort: UInt16, seq: UInt32, ack: UInt32, flags: UInt8, payload: Data) {
        let b = [UInt8](d)
        let ihl = Int(b[0] & 0x0f) * 4
        let t = Array(b[ihl...])
        let off = Int(t[12] >> 4) * 4
        return (UInt16(t[0]) << 8 | UInt16(t[1]), UInt16(t[2]) << 8 | UInt16(t[3]),
                u32(t, 4), u32(t, 8), t[13], Data(t[off...]))
    }

    public static let SYN: UInt8 = 0x02, ACK: UInt8 = 0x10, PSH: UInt8 = 0x08, FIN: UInt8 = 0x01, RST: UInt8 = 0x04

    private static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }
    private static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }
}
