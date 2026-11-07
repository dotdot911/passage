import Foundation
import NIOCore
import NIOPosix
import Packet
import ProxyModel
import Rules

/// Opens UDP sockets towards a destination. Tests redirect to localhost.
public protocol UDPConnector: Sendable {
    func bind(on loop: EventLoop, for destination: IPEndpoint,
              initializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>) -> EventLoopFuture<Channel>
    func target(for destination: IPEndpoint) throws -> SocketAddress
}

public struct DirectUDPConnector: UDPConnector {
    public init() {}
    public func bind(on loop: EventLoop, for destination: IPEndpoint,
                     initializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>) -> EventLoopFuture<Channel> {
        DatagramBootstrap(group: loop)
            .channelInitializer(initializer)
            .bind(host: destination.isIPv6 ? "::" : "0.0.0.0", port: 0)
    }
    public func target(for destination: IPEndpoint) throws -> SocketAddress {
        try SocketAddress(ipAddress: destination.host, port: Int(destination.port))
    }
}

/// NAT for UDP: one socket per (client endpoint, destination) pair, closed after 60 s idle.
/// DNS (port 53) is also parsed: queries become `.dns` flows and answers feed `HostCache`.
/// Resolvers use a fresh source port per lookup, so a DNS socket is closed as soon as all of
/// its queries are answered (or after `dnsIdleTimeout`) to keep the extension's fd count low.
/// All state is confined to `loop`.
public final class UDPRelay: @unchecked Sendable {
    public static let idleTimeout: TimeAmount = .seconds(60)
    public static let defaultDNSIdleTimeout: TimeAmount = .seconds(5)

    struct Key: Hashable {
        let client: IPEndpoint
        let server: IPEndpoint
        var isDNS: Bool { server.port == 53 }
    }

    /// Confined to `loop`, like the rest of the relay state.
    private final class Session: @unchecked Sendable {
        var channel: EventLoopFuture<Channel>
        var idle: Scheduled<Void>?
        var dnsFlows: [UInt16: FlowRecord] = [:]
        /// Queries for names outside the Allow List: relayed but never recorded.
        var silent: Set<UInt16> = []
        init(channel: EventLoopFuture<Channel>) { self.channel = channel }
    }

    private let loop: EventLoop
    private let connector: UDPConnector
    private let sink: FlowSink
    private let hosts: HostCache
    private let emit: @Sendable ([UInt8]) -> Void
    private let dnsIdleTimeout: TimeAmount
    private let rules: @Sendable () -> RuleSet
    private var sessions: [Key: Session] = [:]

    /// - Parameter rules: the rules in force (DNS spoofing, Allow List), read for each query.
    public init(loop: EventLoop, connector: UDPConnector, sink: FlowSink, hosts: HostCache,
                dnsIdleTimeout: TimeAmount = UDPRelay.defaultDNSIdleTimeout,
                rules: @escaping @Sendable () -> RuleSet = { .empty },
                emit: @escaping @Sendable ([UInt8]) -> Void) {
        self.loop = loop
        self.rules = rules
        self.dnsIdleTimeout = dnsIdleTimeout
        self.connector = connector
        self.sink = sink
        self.hosts = hosts
        self.emit = emit
    }

    /// Handles one UDP packet from the tunnel. Safe to call from any thread.
    public func handle(_ packet: IPPacket) {
        guard let udp = packet.udp else { return }
        let key = Key(client: IPEndpoint(address: packet.source, port: udp.sourcePort),
                      server: IPEndpoint(address: packet.destination, port: udp.destinationPort))
        loop.execute { [self] in send(udp.payload, key: key) }
    }

    private func send(_ payload: [UInt8], key: Key) {
        if key.isDNS, let q = DNSMessage(payload), q.isDesignatedResolverDiscovery,
           let reply = DNSMessage.emptyResponse(to: payload) {
            // Answering "no designated resolver" keeps iOS on plain DNS, which we can see and use
            // for host names; otherwise it switches to DNS-over-TLS/HTTPS we cannot decrypt.
            var f = FlowRecord(kind: .dns, host: q.questionName, ip: key.server.host, port: 53)
            f.method = Self.typeName(q.questionType)
            f.url = "dns://\(q.questionName)"
            f.requestBytes = payload.count
            f.responseBytes = reply.count
            f.state = .completed
            f.endedAt = Date()
            f.note = "Blocked encrypted-DNS upgrade (DDR) so DNS stays visible"
            sink.record(f)
            emit(PacketBuilder.udp(source: key.server.address, sourcePort: key.server.port,
                                   destination: key.client.address, destinationPort: key.client.port, payload: reply))
            return
        }
        var recorded = true
        if key.isDNS, let q = DNSMessage(payload), !q.isResponse {
            let rules = rules()
            recorded = rules.allows(host: q.questionName, scheme: "dns")
            if spoof(q, payload: payload, key: key, rules: rules, recorded: recorded) { return }
        }
        let session = sessions[key] ?? open(key)
        if key.isDNS, let q = DNSMessage(payload), !q.isResponse {
            var f = FlowRecord(kind: .dns, host: q.questionName, ip: key.server.host, port: 53)
            f.method = Self.typeName(q.questionType)
            f.url = "dns://\(q.questionName)"
            f.requestBytes = payload.count
            session.dnsFlows[q.id] = f
            if recorded { sink.record(f) } else { session.silent.insert(q.id) }
        }
        touch(session, key: key)
        session.channel.whenSuccess { [connector] ch in
            guard let target = try? connector.target(for: key.server) else { return }
            var buf = ch.allocator.buffer(capacity: payload.count)
            buf.writeBytes(payload)
            ch.writeAndFlush(AddressedEnvelope(remoteAddress: target, data: buf), promise: nil)
        }
    }

    /// Answers an A/AAAA query from a DNS spoofing rule. Returns false when no rule applies.
    private func spoof(_ q: DNSMessage, payload: [UInt8], key: Key, rules: RuleSet, recorded: Bool) -> Bool {
        guard q.questionType == DNSMessage.typeA || q.questionType == DNSMessage.typeAAAA,
              let rule = rules.hostRule(.dnsSpoof, host: q.questionName, scheme: "dns"),
              case .dnsSpoof(let addresses) = rule.action else { return false }
        let size = q.questionType == DNSMessage.typeA ? 4 : 16
        let matching = addresses.filter { IPAddressBytes($0)?.count == size }
        guard let reply = DNSMessage.answerResponse(to: payload, type: q.questionType,
                                                    rdata: matching.compactMap(IPAddressBytes), ttl: 60) else { return false }
        for ip in matching { hosts.remember(ip: ip, host: q.questionName, ttl: 60) }
        if recorded {
            var f = FlowRecord(kind: .dns, host: q.questionName, ip: key.server.host, port: 53)
            f.method = Self.typeName(q.questionType)
            f.url = "dns://\(q.questionName)"
            f.requestBytes = payload.count
            f.responseBytes = reply.count
            f.statusCode = 0
            f.state = .completed
            f.endedAt = Date()
            f.note = "Spoofed by \"\(rule.name)\": " + (matching.isEmpty ? "no \(size == 4 ? "IPv4" : "IPv6") address" : matching.joined(separator: ", "))
            sink.record(f)
        }
        emit(PacketBuilder.udp(source: key.server.address, sourcePort: key.server.port,
                               destination: key.client.address, destinationPort: key.client.port, payload: reply))
        return true
    }

    private func open(_ key: Key) -> Session {
        let reply = ReplyHandler { [weak self] bytes in self?.received(bytes, key: key) }
        let session = Session(channel: connector.bind(on: loop, for: key.server) { ch in
            ch.eventLoop.makeCompletedFuture { try ch.pipeline.syncOperations.addHandler(reply) }
        })
        sessions[key] = session
        session.channel.whenFailure { [weak self, weak session] _ in
            guard let self, let session, sessions[key] === session else { return }
            close(key)
        }
        return session
    }

    private func received(_ bytes: [UInt8], key: Key) {
        guard let session = sessions[key] else { return }
        touch(session, key: key)
        if key.isDNS, let r = DNSMessage(bytes), r.isResponse, var f = session.dnsFlows.removeValue(forKey: r.id) {
            for a in r.answers where a.type == DNSMessage.typeA || a.type == DNSMessage.typeAAAA {
                hosts.remember(ip: a.value, host: r.questionName, ttl: a.ttl)
            }
            f.state = .completed
            f.endedAt = Date()
            f.statusCode = r.responseCode
            f.responseBytes = bytes.count
            f.note = r.answers.isEmpty ? "No answers (rcode \(r.responseCode))" : r.answers.map(\.value).joined(separator: ", ")
            if session.silent.remove(r.id) == nil { sink.record(f) }
        }
        emit(PacketBuilder.udp(source: key.server.address, sourcePort: key.server.port,
                               destination: key.client.address, destinationPort: key.client.port, payload: bytes))
        // Every lookup on this socket is answered: free the fd now instead of waiting for idle.
        if key.isDNS, session.dnsFlows.isEmpty { close(key) }
    }

    private func touch(_ session: Session, key: Key) {
        session.idle?.cancel()
        session.idle = loop.scheduleTask(in: key.isDNS ? dnsIdleTimeout : Self.idleTimeout) { [weak self, weak session] in
            guard let self, let session, sessions[key] === session else { return }
            close(key)
        }
    }

    /// Removes and closes one session; unanswered DNS queries are recorded as failed.
    private func close(_ key: Key) {
        guard let s = sessions.removeValue(forKey: key) else { return }
        s.idle?.cancel()
        s.channel.whenSuccess { $0.close(promise: nil) }
        for (id, var f) in s.dnsFlows where !s.silent.contains(id) {
            f.state = .failed
            f.endedAt = Date()
            f.error = "No DNS response"
            sink.record(f)
        }
        s.dnsFlows.removeAll()
    }

    /// Closes all sockets (tunnel stopping).
    public func closeAll() {
        loop.execute { [self] in
            for key in Array(sessions.keys) { close(key) }
        }
    }

    /// Open sockets. Test hook; call on `loop`.
    var sessionCount: Int { sessions.count }

    static func typeName(_ t: UInt16) -> String {
        switch t {
        case DNSMessage.typeA: "A"
        case DNSMessage.typeAAAA: "AAAA"
        case DNSMessage.typeCNAME: "CNAME"
        case DNSMessage.typeSVCB: "SVCB"
        case 65: "HTTPS"
        default: "TYPE\(t)"
        }
    }
}

private final class ReplyHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    let onReply: ([UInt8]) -> Void
    init(onReply: @escaping ([UInt8]) -> Void) { self.onReply = onReply }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        onReply(Array(unwrapInboundIn(data).data.readableBytesView))
    }
}
