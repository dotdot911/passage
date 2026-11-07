import CertKit
import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import ProxyModel

/// Opens upstream TCP connections. Tests substitute one that dials localhost.
public protocol UpstreamConnector: Sendable {
    func connect(to destination: IPEndpoint, on loop: EventLoop,
                 initializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>) -> EventLoopFuture<Channel>
}

/// Dials the original destination IP. Sockets opened from the Network Extension
/// process are exempt from the tunnel (NECP), so this cannot loop.
public struct DirectConnector: UpstreamConnector {
    public init() {}
    public func connect(to destination: IPEndpoint, on loop: EventLoop,
                        initializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>) -> EventLoopFuture<Channel> {
        ClientBootstrap(group: loop)
            .connectTimeout(.seconds(15))
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .channelInitializer(initializer)
            .connect(host: destination.host, port: Int(destination.port))
    }
}

/// Remembers hosts whose clients reject our certificate (certificate pinning).
/// While disabled, no host is ever treated as pinned and failures are not counted.
public final class PinningTracker: @unchecked Sendable {
    public static let threshold = 2
    private let lock = NSLock()
    private var failures: [String: Int] = [:]
    private var pinned: Set<String>
    private var enabled: Bool
    private let onPinned: @Sendable (String) -> Void

    public init(enabled: Bool = false, pinned: Set<String> = [], onPinned: @escaping @Sendable (String) -> Void = { _ in }) {
        self.enabled = enabled
        self.pinned = pinned
        self.onPinned = onPinned
    }

    public func isPinned(_ host: String) -> Bool { lock.withLock { enabled && pinned.contains(host) } }

    public func setEnabled(_ on: Bool) { lock.withLock { enabled = on; failures.removeAll() } }

    /// True once any client accepted one of our leaf certificates, i.e. the root CA is trusted.
    /// Until then every host fails the handshake, so failures say nothing about pinning.
    public var caTrusted: Bool { lock.withLock { trusted } }
    private var trusted = false

    public func recordFailure(_ host: String) {
        let newlyPinned: Bool = lock.withLock {
            guard enabled, trusted else { return false }
            let n = (failures[host] ?? 0) + 1
            failures[host] = n
            guard n >= Self.threshold, !pinned.contains(host) else { return false }
            pinned.insert(host)
            return true
        }
        if newlyPinned { onPinned(host) }
    }

    public func recordSuccess(_ host: String) { lock.withLock { failures[host] = nil; trusted = true } }

    /// Replaces the pinned set (after the user unpinned hosts in Settings).
    public func replacePinned(_ hosts: Set<String>) { lock.withLock { pinned = hosts; failures.removeAll() } }

    public func unpin(_ host: String) { lock.withLock { pinned.remove(host); failures[host] = nil } }
}

/// Decides what happens to a request head before it goes upstream.
public enum RequestDecision: Sendable {
    case forward(HTTPRequestHeadSnapshot)
    case respond(status: Int, headers: [HeaderField], body: [UInt8])
}

/// A value copy of a request head handed to hooks.
public struct HTTPRequestHeadSnapshot: Sendable {
    public var method: String
    public var uri: String
    public var headers: [HeaderField]
    public init(method: String, uri: String, headers: [HeaderField]) {
        self.method = method; self.uri = uri; self.headers = headers
    }
}

/// Extension point for sub-projects 3 (rules) and 6 (scripting). Core ships no hooks.
public protocol RequestHeadHook: Sendable {
    func decide(flow: FlowRecord, head: HTTPRequestHeadSnapshot) -> RequestDecision
}

/// Everything the engine needs. One instance per tunnel session.
public struct EngineConfig: Sendable {
    public var ca: CertificateAuthority
    public var sink: FlowSink
    public var connector: UpstreamConnector
    public var pinning: PinningTracker
    /// Trust settings for upstream TLS. Defaults to the system trust store.
    public var upstreamTLS: TLSConfiguration
    /// Why `host` must not be decrypted (excluded by the user, low memory...), or nil to decrypt it.
    public var bypassReason: @Sendable (String) -> String?
    /// The tunnel's own address; connections to it are served by `InternalSite`.
    public var internalAddress: [UInt8]
    public var hooks: [RequestHeadHook]
    /// When false, flows still get recorded but bodies are skipped (low-memory mode).
    public var recordBodies: @Sendable () -> Bool
    /// Map Local, Map Remote, Block, Breakpoint… Nil runs without rules.
    public var rules: RuleEngine?
    /// Whether decrypted connections may use HTTP/2 when both the client and the server offer it.
    public var http2Enabled: @Sendable () -> Bool
    /// Closes idle decrypted connections. Nil keeps them open for as long as the client does.
    public var reaper: IdleReaper?

    public init(ca: CertificateAuthority, sink: FlowSink, connector: UpstreamConnector = DirectConnector(),
                pinning: PinningTracker = PinningTracker(), upstreamTLS: TLSConfiguration = .makeClientConfiguration(),
                bypassReason: @escaping @Sendable (String) -> String? = { _ in nil },
                internalAddress: [UInt8] = [198, 18, 0, 1], hooks: [RequestHeadHook] = [],
                recordBodies: @escaping @Sendable () -> Bool = { true }, rules: RuleEngine? = nil,
                http2Enabled: @escaping @Sendable () -> Bool = { true }, reaper: IdleReaper? = nil) {
        self.ca = ca; self.sink = sink; self.connector = connector; self.pinning = pinning
        self.upstreamTLS = upstreamTLS; self.bypassReason = bypassReason
        self.internalAddress = internalAddress; self.hooks = hooks; self.recordBodies = recordBodies
        self.rules = rules; self.http2Enabled = http2Enabled; self.reaper = reaper
    }
}
