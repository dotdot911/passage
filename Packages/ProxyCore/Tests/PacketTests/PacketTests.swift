import Packet
import ProxyModel
import Testing

@Suite struct PacketTests {
    let client: [UInt8] = [198, 18, 0, 2]
    let resolver: [UInt8] = [8, 8, 8, 8]

    @Test func udpPacketRoundTripsThroughParser() throws {
        let bytes = PacketBuilder.udp(source: resolver, sourcePort: 53, destination: client, destinationPort: 5353,
                                      payload: [1, 2, 3])
        let p = try #require(IPPacket(bytes: bytes))
        #expect(p.version == 4)
        #expect(p.proto == .udp)
        #expect(p.source == resolver)
        #expect(p.udp == UDPDatagram(sourcePort: 53, destinationPort: 5353, payload: [1, 2, 3]))
    }

    @Test func ipv4HeaderChecksumIsValid() {
        let bytes = PacketBuilder.udp(source: resolver, sourcePort: 53, destination: client, destinationPort: 1, payload: [])
        // Summing a header that contains its own checksum yields 0xffff, i.e. finish() == 0.
        #expect(Self.onesComplement(Array(bytes[0..<20])) == 0)
    }

    @Test func udpChecksumIsValidForIPv4AndIPv6() {
        for (src, dst) in [(resolver, client), ([UInt8](repeating: 0, count: 15) + [1], [0xfd, 0, 0x50, 0x50] + [UInt8](repeating: 0, count: 11) + [2])] {
            let bytes = PacketBuilder.udp(source: src, sourcePort: 53, destination: dst, destinationPort: 999, payload: [9, 8, 7])
            let p = IPPacket(bytes: bytes)!
            let udp = Array(bytes[p.payloadOffset...])
            var pseudo = src + dst
            pseudo += src.count == 4 ? [0, 17, 0, UInt8(udp.count)] : [0, 0, 0, UInt8(udp.count), 0, 0, 0, 17]
            #expect(Self.onesComplement(pseudo + udp) == 0)
        }
    }

    @Test func portUnreachableQuotesOriginalAndSwapsAddresses() throws {
        let quic = PacketBuilder.udp(source: client, sourcePort: 50000, destination: [142, 250, 0, 1], destinationPort: 443,
                                     payload: [UInt8](repeating: 0xab, count: 100))
        let reply = PacketBuilder.portUnreachable(for: IPPacket(bytes: quic)!)
        let p = try #require(IPPacket(bytes: reply))
        #expect(p.proto == .icmp)
        #expect(p.source == [142, 250, 0, 1])
        #expect(p.destination == client)
        #expect(Array(reply[20..<22]) == [3, 3])
        #expect(Array(reply[28..<(28 + 28)]) == Array(quic[0..<28]))
        #expect(Self.onesComplement(Array(reply[20...])) == 0)
    }

    @Test func dnsResponseWithCompressionIsParsed() throws {
        // Response for api.example.com: CNAME edge.example.net, then A 93.184.216.34 (names compressed).
        var m: [UInt8] = [0x12, 0x34, 0x81, 0x80, 0, 1, 0, 2, 0, 0, 0, 0]
        m += dnsName("api.example.com")
        m += [0, 1, 0, 1]
        let cnameTarget = dnsName("edge.example.net")
        m += [0xc0, 12, 0, 5, 0, 1, 0, 0, 0, 60, 0, UInt8(cnameTarget.count)] + cnameTarget
        let targetOffset = UInt8(12 + 17 + 4 + 12)
        m += [0xc0, targetOffset, 0, 1, 0, 1, 0, 0, 1, 0, 0, 4, 93, 184, 216, 34]

        let dns = try #require(DNSMessage(m))
        #expect(dns.id == 0x1234)
        #expect(dns.isResponse)
        #expect(dns.questionName == "api.example.com")
        #expect(dns.questionType == DNSMessage.typeA)
        #expect(dns.answers.map(\.value) == ["edge.example.net", "93.184.216.34"])
        #expect(dns.answers[1].name == "edge.example.net")
        #expect(dns.answers[1].ttl == 256)
    }

    @Test func ipv6TextCompressesLongestZeroRun() {
        #expect(IPv6Text([0xfd, 0, 0x50, 0x50] + [UInt8](repeating: 0, count: 11) + [1]) == "fd00:5050::1")
        #expect(IPv6Text([0x20, 0x01, 0x0d, 0xb8, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]) == "2001:db8:1::1")
    }

    @Test func emptyResponseEchoesQuestionWithNoAnswers() throws {
        var q: [UInt8] = [0xbe, 0xef, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 1]
        q += dnsName("_dns.resolver.arpa")
        q += [0, 64, 0, 1]
        q += [0, 0, 41, 4, 0xd0, 0, 0, 0, 0, 0, 0] // EDNS OPT record, must be dropped
        let query = try #require(DNSMessage(q))
        #expect(query.isDesignatedResolverDiscovery)

        let r = try #require(DNSMessage.emptyResponse(to: q))
        let parsed = try #require(DNSMessage(r))
        #expect(parsed.id == 0xbeef)
        #expect(parsed.isResponse)
        #expect(parsed.responseCode == 0)
        #expect(parsed.questionName == "_dns.resolver.arpa")
        #expect(parsed.answers.isEmpty)
        #expect(Array(r[6..<12]) == [0, 0, 0, 0, 0, 0])
        #expect(r.count == 12 + 20 + 4)
    }

    static func onesComplement(_ b: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < b.count { sum += UInt32(b[i]) << 8 | UInt32(b[i + 1]); i += 2 }
        if i < b.count { sum += UInt32(b[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum)
    }
}

/// A DNS name in wire format: length-prefixed labels and a terminating zero.
private func dnsName(_ name: String) -> [UInt8] {
    var out: [UInt8] = []
    for label in name.split(separator: ".") {
        out.append(UInt8(label.utf8.count))
        out.append(contentsOf: Array(label.utf8))
    }
    out.append(0)
    return out
}
