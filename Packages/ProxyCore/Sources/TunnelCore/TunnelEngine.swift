import Bridge
import CertKit
import Foundation
import HTTPEngine
import NIOCore
import NIOPosix
import NIOSSL
import NetStack
import Packet
import ProxyModel
import Rules

/// Composition root of the extension: packets in, packets out, flows recorded.
/// The `NEPacketTunnelProvider` only feeds `handle(_:)` and implements `writePackets`.
public final class TunnelEngine: NetStackDelegate, @unchecked Sendable {
    public struct Options: Sendable {
        public var ca: CertificateAuthority
        public var sink: FlowSink
        public var connector: UpstreamConnector = DirectConnector()
        public var udpConnector: UDPConnector = DirectUDPConnector()
        public var upstreamTLS: TLSConfiguration = .makeClientConfiguration()
        public var excludedHosts: [String] = []
        /// Decrypt every host (except excluded ones) instead of only `sslProxyingHosts`.
        public var decryptAll = false
        public var sslProxyingHosts: [String] = []
        /// Map Local, Block, Breakpoint… and DNS spoofing. Nil runs without rules.
        public var rules: RuleEngine?
        public var autoPinning = false
        /// Offer HTTP/2 on decrypted connections.
        public var http2Enabled = true
        public var pinnedHosts: Set<String> = []
        public var onPinned: @Sendable (String) -> Void = { _ in }
        public var memoryProbe: @Sendable () -> Int? = MemoryMonitor.systemAvailableBytes
        public var onLowMemoryChange: @Sendable (Bool) -> Void = { _ in }
        public init(ca: CertificateAuthority, sink: FlowSink) { self.ca = ca; self.sink = sink }
    }

    public static let tunnelAddress: [UInt8] = [198, 18, 0, 1]

    public let hosts = HostCache()
    public let pinning: PinningTracker
    private let options: Options
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let stack = NetStack.shared
    private let writePackets: @Sendable ([Data]) -> Void
    private let lock = NSLock()
    private var matcher: HostMatcher
    private var ssl: (all: Bool, hosts: HostMatcher)
    private var http2: Bool
    private var router: FlowRouter!
    private var udp: UDPRelay!
    private var memory: MemoryMonitor!
    private var reaper: IdleReaper?
    private var outbox: [Data] = []
    private var stopped = false

    public init(options: Options, writePackets: @escaping @Sendable ([Data]) -> Void) {
        self.options = options
        self.writePackets = writePackets
        self.matcher = HostMatcher(options.excludedHosts)
        self.ssl = (options.decryptAll, HostMatcher(options.sslProxyingHosts))
        self.http2 = options.http2Enabled
        self.pinning = PinningTracker(enabled: options.autoPinning, pinned: options.pinnedHosts, onPinned: options.onPinned)
    }

    public func start() throws {
        let reaper = IdleReaper()
        self.reaper = reaper
        memory = MemoryMonitor(probe: options.memoryProbe) { [weak self] low in
            if low { self?.options.ca.trimCache(to: 32) }
            reaper.setPressure(low)
            self?.options.onLowMemoryChange(low)
        }
        let config = EngineConfig(
            ca: options.ca, sink: options.sink, connector: options.connector, pinning: pinning,
            upstreamTLS: options.upstreamTLS,
            bypassReason: { [weak self] host in
                guard let self else { return nil }
                let excluded: HostMatcher = lock.withLock { self.matcher }
                let proxying: (all: Bool, hosts: HostMatcher) = lock.withLock { self.ssl }
                return HostMatcher.bypassReason(host, excluded: excluded, decryptAll: proxying.all,
                                         sslProxying: proxying.hosts, lowMemory: memory.isLowNow)
            },
            internalAddress: Self.tunnelAddress,
            recordBodies: { [weak self] in !(self?.memory.isLow ?? false) },
            rules: options.rules,
            http2Enabled: { [weak self] in self.map { s in s.lock.withLock { s.http2 } } ?? true },
            reaper: reaper)
        router = try FlowRouter(config: config)
        udp = UDPRelay(loop: group.next(), connector: options.udpConnector, sink: options.sink, hosts: hosts,
                       rules: { [rules = options.rules] in rules?.current ?? .empty }) { [writePackets] bytes in
            writePackets([Data(bytes)])
        }
        memory.start()
        reaper.start()
        stack.queue.sync {
            stack.delegate = self
            stack.start()
        }
    }

    public func stop() {
        lock.withLock { stopped = true }
        options.rules?.breakpoints.cancelAll()
        memory?.stop()
        reaper?.stop()
        udp?.closeAll()
        stack.queue.sync {
            for conn in Array(stack.connections.values) { conn.abort(notify: true) }
            if stack.delegate === self { stack.delegate = nil }
        }
        group.shutdownGracefully { _ in }
    }

    /// Applies to connections opened from now on.
    public func updateHTTP2(_ enabled: Bool) { lock.withLock { http2 = enabled } }

    /// Aborts every client connection (network interface changed); clients reconnect.
    public func dropAllConnections() {
        stack.queue.async { [stack] in
            for conn in Array(stack.connections.values) { conn.abort(notify: true) }
        }
    }

    public var activeConnections: Int { stack.queue.sync { stack.connections.count } }
    public var isLowMemory: Bool { memory?.isLow ?? false }

    /// Sends a request composed in the app; the result is recorded through the engine's sink.
    public func send(flowID: UUID, request: ComposedRequest, body: Data?) {
        Composer.send(flowID: flowID, request: request, body: body, tls: options.upstreamTLS,
                      sink: options.sink, group: group)
    }

    public func updateExcludedHosts(_ patterns: [String]) {
        let m = HostMatcher(patterns)
        lock.withLock { matcher = m }
    }

    public func updateSSLProxying(decryptAll: Bool, hosts: [String]) {
        let m = HostMatcher(hosts)
        lock.withLock { ssl = (decryptAll, m) }
    }

    /// Packets read from `packetFlow`. Call from any thread.
    public func handle(_ packets: [Data]) {
        guard !lock.withLock({ stopped || udp == nil || router == nil }) else { return }
        var tcp: [Data] = []
        for p in packets {
            guard let first = p.first else { continue }
            let version = first >> 4
            guard (version == 4 && p.count >= 20) || (version == 6 && p.count >= 40) else { continue }
            let proto = version == 4 ? p[p.startIndex + 9] : p[p.startIndex + 6]
            switch proto {
            case 6:
                tcp.append(p)
            case 17:
                guard let ip = IPPacket(p), let datagram = ip.udp else { continue }
                if datagram.destinationPort == 443 {
                    // QUIC/HTTP3 cannot be decrypted: refuse it so the client falls back to TCP+TLS.
                    writePackets([Data(PacketBuilder.portUnreachable(for: ip))])
                } else {
                    udp.handle(ip)
                }
            default:
                continue // ICMP etc. are not forwarded in Core.
            }
        }
        guard !tcp.isEmpty else { return }
        let batch = tcp
        stack.queue.async { [stack] in
            for p in batch { stack.input(p) }
        }
    }

    // MARK: NetStackDelegate (on stack.queue)

    public func netStack(_ stack: NetStack, emit packet: Data) {
        outbox.append(packet)
        if outbox.count == 1 {
            // Coalesce everything lwIP emits during this queue turn into one writePackets call.
            stack.queue.async { [self] in
                let batch = outbox
                outbox.removeAll(keepingCapacity: true)
                if lock.withLock({ stopped }) { return }
                writePackets(batch)
            }
        }
    }

    public func netStack(_ stack: NetStack, didAccept connection: TCPConnection) {
        let destination = connection.destination
        let hint = hosts.host(for: destination.host)
        let router = self.router!
        _ = SocketBridge.attach(connection, stack: stack, group: group) { ch in
            router.install(on: ch, destination: destination, hostHint: hint)
        }
    }
}
