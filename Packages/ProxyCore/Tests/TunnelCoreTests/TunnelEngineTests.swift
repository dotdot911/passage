import CertKit
import Foundation
import HTTPEngine
import NIOCore
import NIOHTTP1
import NIOPosix
import Packet
import ProxyModel
import Rules
import Testing
import TestSupport
@testable import TunnelCore

/// Collects packets the engine writes back into the tunnel.
final class PacketSink: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [Data] = []
    func write(_ batch: [Data]) { lock.withLock { packets += batch } }
    var all: [Data] { lock.withLock { packets } }

    func waitFor(_ predicate: ([Data]) -> Bool) async -> Bool {
        for _ in 0..<300 {
            if predicate(all) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate(all)
    }
}

/// Sends every UDP datagram to a local server instead of the real destination.
struct LocalUDPConnector: UDPConnector {
    let target: SocketAddress
    func bind(on loop: EventLoop, for destination: IPEndpoint,
              initializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>) -> EventLoopFuture<Channel> {
        DatagramBootstrap(group: loop).channelInitializer(initializer).bind(host: "127.0.0.1", port: 0)
    }
    func target(for destination: IPEndpoint) throws -> SocketAddress { target }
}

/// Answers any DNS query with one A record (93.184.216.34, TTL 300).
final class FakeDNSHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let env = unwrapInboundIn(data)
        var q = Array(env.data.readableBytesView)
        q[2] = 0x81; q[3] = 0x80; q[7] = 1 // response, 1 answer
        q += [0xc0, 12, 0, 1, 0, 1, 0, 0, 1, 0x2c, 0, 4, 93, 184, 216, 34]
        context.writeAndFlush(wrapOutboundOut(AddressedEnvelope(remoteAddress: env.remoteAddress,
                                                                data: context.channel.allocator.buffer(bytes: q))), promise: nil)
    }
}

final class HelloServer: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private var uri = ""
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h): uri = h.uri
        case .body: break
        case .end:
            let text = "hello \(uri)"
            var h = HTTPHeaders([("content-length", "\(text.utf8.count)"), ("connection", "close")])
            h.add(name: "x-test", value: "1")
            context.write(wrapOutboundOut(.head(.init(version: .http1_1, status: .ok, headers: h))), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(context.channel.allocator.buffer(string: text)))), promise: nil)
            let channel = context.channel
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in channel.close(promise: nil) }
        }
    }
}

@Suite(.serialized) struct TunnelEngineTests {
    let client: [UInt8] = [198, 18, 0, 2]

    func makeEngine(sink: MemorySink, packets: PacketSink, tcpTarget: SocketAddress, udpTarget: SocketAddress) throws -> TunnelEngine {
        var options = TunnelEngine.Options(ca: try CertificateAuthority.generate(), sink: sink)
        options.connector = LocalConnector(target: tcpTarget)
        options.udpConnector = LocalUDPConnector(target: udpTarget)
        options.memoryProbe = { nil }
        let engine = TunnelEngine(options: options) { packets.write($0) }
        try engine.start()
        return engine
    }

    @Test func httpRequestThroughTunnelIsAnsweredAndRecorded() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let upstream = try await ServerBootstrap(group: group)
            .childChannelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    try ch.pipeline.syncOperations.configureHTTPServerPipeline()
                    try ch.pipeline.syncOperations.addHandler(HelloServer())
                }
            }.bind(host: "127.0.0.1", port: 0).get()
        let sink = MemorySink(), packets = PacketSink()
        let engine = try makeEngine(sink: sink, packets: packets, tcpTarget: upstream.localAddress!,
                                    udpTarget: try SocketAddress(ipAddress: "127.0.0.1", port: 9))
        defer { engine.stop() }
        let port: UInt16 = 50300

        engine.handle([PacketFixtures.tcp4(srcPort: port, dstPort: 80, seq: 100, flags: PacketFixtures.SYN)])
        #expect(await packets.waitFor { !$0.isEmpty })
        let synAck = PacketFixtures.parseTCP4(packets.all[0])
        engine.handle([
            PacketFixtures.tcp4(srcPort: port, dstPort: 80, seq: 101, ack: synAck.seq + 1, flags: PacketFixtures.ACK),
            PacketFixtures.tcp4(srcPort: port, dstPort: 80, seq: 101, ack: synAck.seq + 1,
                                flags: PacketFixtures.ACK | PacketFixtures.PSH,
                                payload: Array("GET /tunnel HTTP/1.1\r\nHost: api.test\r\nConnection: close\r\n\r\n".utf8)),
        ])

        let responded = await packets.waitFor { all in
            let text = all.map { String(decoding: PacketFixtures.parseTCP4($0).payload, as: UTF8.self) }.joined()
            return text.contains("hello /tunnel")
        }
        #expect(responded)
        #expect(await sink.waitFor { $0.contains { $0.url == "http://api.test/tunnel" && $0.statusCode == 200 } })
    }

    @Test func dnsIsRelayedRecordedAndTeachesHostCache() async throws {
        let dns = try await DatagramBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelInitializer { ch in ch.eventLoop.makeCompletedFuture { try ch.pipeline.syncOperations.addHandler(FakeDNSHandler()) } }
            .bind(host: "127.0.0.1", port: 0).get()
        let sink = MemorySink(), packets = PacketSink()
        let engine = try makeEngine(sink: sink, packets: packets, tcpTarget: try SocketAddress(ipAddress: "127.0.0.1", port: 9),
                                    udpTarget: dns.localAddress!)
        defer { engine.stop() }
        var query: [UInt8] = [0xab, 0xcd, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        query += dnsName("api.example.com")
        query += [0, 1, 0, 1]

        engine.handle([Data(PacketBuilder.udp(source: client, sourcePort: 5353, destination: [8, 8, 8, 8],
                                              destinationPort: 53, payload: query))])

        #expect(await packets.waitFor { !$0.isEmpty })
        let reply = try #require(IPPacket(packets.all[0])?.udp)
        #expect(reply.sourcePort == 53 && reply.destinationPort == 5353)
        #expect(DNSMessage(reply.payload)?.answers.first?.value == "93.184.216.34")
        #expect(engine.hosts.host(for: "93.184.216.34") == "api.example.com")
        #expect(await sink.waitFor { $0.contains { $0.kind == .dns && $0.host == "api.example.com" && $0.state == .completed } })
    }

    @Test func dropAllConnectionsClosesBridgedAndUpstreamChannels() async throws {
        let accepted = ChannelList()
        let upstream = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { ch in accepted.append(ch); return ch.eventLoop.makeSucceededVoidFuture() }
            .bind(host: "127.0.0.1", port: 0).get()
        defer { upstream.close(promise: nil) }
        let sink = MemorySink(), packets = PacketSink()
        let engine = try makeEngine(sink: sink, packets: packets, tcpTarget: upstream.localAddress!,
                                    udpTarget: try SocketAddress(ipAddress: "127.0.0.1", port: 9))
        defer { engine.stop() }
        let port: UInt16 = 50310

        engine.handle([PacketFixtures.tcp4(srcPort: port, dstPort: 80, seq: 100, flags: PacketFixtures.SYN)])
        #expect(await packets.waitFor { !$0.isEmpty })
        let synAck = PacketFixtures.parseTCP4(packets.all[0])
        engine.handle([
            PacketFixtures.tcp4(srcPort: port, dstPort: 80, seq: 101, ack: synAck.seq + 1, flags: PacketFixtures.ACK),
            PacketFixtures.tcp4(srcPort: port, dstPort: 80, seq: 101, ack: synAck.seq + 1,
                                flags: PacketFixtures.ACK | PacketFixtures.PSH,
                                payload: Array("GET /hold HTTP/1.1\r\nHost: api.test\r\n\r\n".utf8)),
        ])
        // The upstream never answers, so the flow stays open until the engine drops it.
        #expect(await packets.waitFor { _ in !accepted.all.isEmpty })
        let held = try #require(accepted.all.first)
        #expect(held.isActive)

        engine.dropAllConnections()

        // abort(notify:) -> pump closes -> socketpair EOF -> engine channel inactive -> upstream closed.
        #expect(await packets.waitFor { _ in !held.isActive })
        #expect(engine.activeConnections == 0)
    }

    @Test func dnsSocketClosesOnceAnswered() async throws {
        let dns = try await DatagramBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelInitializer { ch in ch.eventLoop.makeCompletedFuture { try ch.pipeline.syncOperations.addHandler(FakeDNSHandler()) } }
            .bind(host: "127.0.0.1", port: 0).get()
        defer { dns.close(promise: nil) }
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let sink = MemorySink(), packets = PacketSink()
        let relay = UDPRelay(loop: loop, connector: LocalUDPConnector(target: dns.localAddress!), sink: sink,
                             hosts: HostCache()) { packets.write([Data($0)]) }

        relay.handle(try #require(IPPacket(Data(dnsQuery(id: 0x1111)))))

        #expect(await packets.waitFor { !$0.isEmpty })
        #expect(try await loop.submit { relay.sessionCount }.get() == 0)
        #expect(await sink.waitFor { $0.contains { $0.kind == .dns && $0.state == .completed } })
    }

    @Test func unansweredDNSIsRecordedAsFailedWhenSocketCloses() async throws {
        // Bound but silent: queries are swallowed.
        let silent = try await DatagramBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(host: "127.0.0.1", port: 0).get()
        defer { silent.close(promise: nil) }
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let sink = MemorySink(), packets = PacketSink()
        let relay = UDPRelay(loop: loop, connector: LocalUDPConnector(target: silent.localAddress!), sink: sink,
                             hosts: HostCache(), dnsIdleTimeout: .milliseconds(100)) { packets.write([Data($0)]) }

        relay.handle(try #require(IPPacket(Data(dnsQuery(id: 0x2222)))))

        #expect(await sink.waitFor { $0.contains { $0.kind == .dns && $0.state == .failed && $0.error == "No DNS response" } })
        #expect(try await loop.submit { relay.sessionCount }.get() == 0)
    }

    func dnsQuery(id: UInt16, type: UInt8 = 1) -> [UInt8] {
        var query: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xff), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        query += dnsName("api.test")
        query += [0, type, 0, 1]
        return PacketBuilder.udp(source: client, sourcePort: 40000, destination: [8, 8, 8, 8], destinationPort: 53, payload: query)
    }

    @Test func dnsSpoofAnswersLocallyPerAddressFamily() async throws {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let sink = MemorySink(), packets = PacketSink(), hosts = HostCache()
        let rule = Rule(tool: .dnsSpoof, name: "local", match: URLMatch(pattern: "*.test"), action: .dnsSpoof(addresses: ["10.1.2.3"]))
        let set = RuleSet(rules: [rule], enabledTools: [.dnsSpoof])
        let dead = try SocketAddress(ipAddress: "127.0.0.1", port: 9)
        let relay = UDPRelay(loop: loop, connector: LocalUDPConnector(target: dead), sink: sink, hosts: hosts,
                             rules: { set }) { packets.write([Data($0)]) }

        relay.handle(try #require(IPPacket(Data(dnsQuery(id: 0x0a0a)))))
        relay.handle(try #require(IPPacket(Data(dnsQuery(id: 0x0b0b, type: 28)))))
        #expect(await packets.waitFor { $0.count == 2 })
        let a = try #require(IPPacket(packets.all[0])?.udp.flatMap { DNSMessage($0.payload) })
        #expect(a.id == 0x0a0a && a.answers.map(\.value) == ["10.1.2.3"] && a.answers.first?.ttl == 60)
        let aaaa = try #require(IPPacket(packets.all[1])?.udp.flatMap { DNSMessage($0.payload) })
        #expect(aaaa.isResponse && aaaa.answers.isEmpty)
        #expect(hosts.host(for: "10.1.2.3") == "api.test")
        #expect(await sink.waitFor { $0.contains { $0.note == "Spoofed by \"local\": 10.1.2.3" } })
        #expect(try await loop.submit { relay.sessionCount }.get() == 0)
    }

    @Test func dnsOutsideTheAllowListIsRelayedButNotRecorded() async throws {
        let dns = try await DatagramBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelInitializer { ch in ch.eventLoop.makeCompletedFuture { try ch.pipeline.syncOperations.addHandler(FakeDNSHandler()) } }
            .bind(host: "127.0.0.1", port: 0).get()
        defer { dns.close(promise: nil) }
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let sink = MemorySink(), packets = PacketSink()
        let set = RuleSet(rules: [Rule(tool: .allowList, name: "only", match: URLMatch(pattern: "only.example"), action: .allow)],
                          enabledTools: [.allowList])
        let relay = UDPRelay(loop: loop, connector: LocalUDPConnector(target: dns.localAddress!), sink: sink,
                             hosts: HostCache(), rules: { set }) { packets.write([Data($0)]) }

        relay.handle(try #require(IPPacket(Data(dnsQuery(id: 0x3333)))))
        #expect(await packets.waitFor { !$0.isEmpty })
        try await Task.sleep(for: .milliseconds(50))
        #expect(sink.all.isEmpty)
    }

    @Test func ddrProbeIsAnsweredLocallyWithNoResolvers() async throws {
        let sink = MemorySink(), packets = PacketSink()
        let dead = try SocketAddress(ipAddress: "127.0.0.1", port: 9)
        let engine = try makeEngine(sink: sink, packets: packets, tcpTarget: dead, udpTarget: dead)
        defer { engine.stop() }
        var query: [UInt8] = [0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        query += dnsName("_dns.resolver.arpa")
        query += [0, 64, 0, 1]

        engine.handle([Data(PacketBuilder.udp(source: client, sourcePort: 5300, destination: [1, 1, 1, 1],
                                              destinationPort: 53, payload: query))])

        #expect(await packets.waitFor { !$0.isEmpty })
        let reply = try #require(IPPacket(packets.all[0])?.udp)
        #expect(reply.sourcePort == 53 && reply.destinationPort == 5300)
        let dns = try #require(DNSMessage(reply.payload))
        #expect(dns.isResponse && dns.answers.isEmpty && dns.id == 0x1234)
        #expect(await sink.waitFor { $0.contains { $0.method == "SVCB" && $0.note?.contains("DDR") == true } })
    }

    @Test func quicIsRefusedWithPortUnreachable() async throws {
        let sink = MemorySink(), packets = PacketSink()
        let dead = try SocketAddress(ipAddress: "127.0.0.1", port: 9)
        let engine = try makeEngine(sink: sink, packets: packets, tcpTarget: dead, udpTarget: dead)
        defer { engine.stop() }

        engine.handle([Data(PacketBuilder.udp(source: client, sourcePort: 61000, destination: [142, 250, 0, 1],
                                              destinationPort: 443, payload: [0xc0, 0, 0, 0, 1]))])

        let icmp = try #require(packets.all.first.flatMap { IPPacket($0) })
        #expect(icmp.proto == .icmp)
        #expect(icmp.destination == client)
    }

    @Test func packetsAfterStopAreIgnored() async throws {
        let sink = MemorySink(), packets = PacketSink()
        let dead = try SocketAddress(ipAddress: "127.0.0.1", port: 9)
        let engine = try makeEngine(sink: sink, packets: packets, tcpTarget: dead, udpTarget: dead)
        engine.stop()
        var query: [UInt8] = [0xab, 0xcd, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        query += dnsName("api.com")
        query += [0, 1, 0, 1]

        engine.handle([
            Data(PacketBuilder.udp(source: client, sourcePort: 5353, destination: [8, 8, 8, 8],
                                   destinationPort: 53, payload: query)),
            PacketFixtures.tcp4(srcPort: 50400, dstPort: 80, seq: 1, flags: PacketFixtures.SYN),
        ])

        try await Task.sleep(for: .milliseconds(200))
        #expect(packets.all.isEmpty)
    }

    @Test func memoryMonitorUsesHysteresis() {
        let available = Counter(start: 50 << 20)
        let changes = Changes()
        let m = MemoryMonitor(probe: { available.value }) { changes.append($0) }
        m.check()
        available.set(15 << 20); m.check()
        available.set(20 << 20); m.check()
        available.set(25 << 20); m.check()
        #expect(changes.values == [true, false])
    }

    @Test func aDropBetweenPollsIsSeenAtOnce() {
        let available = Counter(start: 50 << 20)
        let m = MemoryMonitor(probe: { available.value }) { _ in }
        m.check()
        available.set(8 << 20)
        #expect(!m.isLow)
        #expect(m.isLowNow)
    }

    @Test func onlySSLProxyingHostsAreDecryptedUnlessDecryptAll() {
        let none = HostMatcher([]), list = HostMatcher(["*.api.test"]), bank = HostMatcher(["bank.api.test"])
        func reason(_ host: String, excluded: HostMatcher = none, all: Bool = false, low: Bool = false) -> String? {
            HostMatcher.bypassReason(host, excluded: excluded, decryptAll: all, sslProxying: list, lowMemory: low)
        }
        #expect(reason("google.com") == "SSL Proxying is off for this host")
        #expect(reason("v1.api.test") == nil)
        #expect(reason("google.com", all: true) == nil)
        #expect(reason("bank.api.test", excluded: bank, all: true) == "Excluded from SSL proxying")
        #expect(reason("v1.api.test", low: true) == "Low memory: not decrypted")
    }

    @Test func hostMatcherSupportsWildcards() {
        let m = HostMatcher(["*.apple.com", "Bank.test"])
        #expect(m.matches("apple.com"))
        #expect(m.matches("api.apple.com"))
        #expect(m.matches("bank.test"))
        #expect(!m.matches("notapple.com"))
        #expect(!m.matches("api.bank.test"))
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n: Int
    init(start: Int) { n = start }
    func set(_ v: Int) { lock.withLock { n = v } }
    var value: Int { lock.withLock { n } }
}

final class Changes: @unchecked Sendable {
    private let lock = NSLock()
    private var v: [Bool] = []
    func append(_ b: Bool) { lock.withLock { v.append(b) } }
    var values: [Bool] { lock.withLock { v } }
}

final class ChannelList: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [Channel] = []
    func append(_ c: Channel) { lock.withLock { channels.append(c) } }
    var all: [Channel] { lock.withLock { channels } }
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
