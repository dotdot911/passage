import CertKit
import Foundation
import NIOCore
import NIOConcurrencyHelpers
import NIOHTTP1
import NIOHTTP2
import NIOSSL
import ProxyModel

/// Entry point of the engine: decides what to do with each client TCP connection.
public final class FlowRouter: Sendable {
    public let config: EngineConfig
    /// Upstream TLS contexts keyed by their ALPN list.
    private let upstreamContexts: NIOLockedValueBox<[[String]: NIOSSLContext]>

    public init(config: EngineConfig) throws {
        self.config = config
        self.upstreamContexts = NIOLockedValueBox([:])
        _ = try upstreamContext(alpn: ["http/1.1"])
    }

    private init(config: EngineConfig, contexts: NIOLockedValueBox<[[String]: NIOSSLContext]>) {
        self.config = config
        self.upstreamContexts = contexts
    }

    /// The same router reporting to `sink`, sharing its upstream TLS contexts; cheap enough for each connection.
    public func routing(to sink: FlowSink) -> FlowRouter {
        var config = config
        config.sink = sink
        return FlowRouter(config: config, contexts: upstreamContexts)
    }

    private func upstreamContext(alpn: [String]) throws -> NIOSSLContext {
        try upstreamContexts.withLockedValue { cache in
            if let ctx = cache[alpn] { return ctx }
            var tls = config.upstreamTLS
            tls.applicationProtocols = alpn
            let ctx = try NIOSSLContext(configuration: tls)
            cache[alpn] = ctx
            return ctx
        }
    }

    /// What to offer the server: the client's own list reduced to the protocols the engine speaks.
    func upstreamALPN(for clientALPN: [String]) -> [String] {
        if clientALPN.isEmpty { return ["http/1.1"] }
        let h2 = config.http2Enabled()
        return clientALPN.filter { $0 == "http/1.1" || (h2 && $0 == "h2") }
    }

    /// Installs the sniffer on a fresh client channel. Use as a channel initializer.
    /// - Parameter hostHint: hostname learned from DNS for `destination`, if any.
    public func install(on channel: Channel, destination: IPEndpoint, hostHint: String?) -> EventLoopFuture<Void> {
        channel.eventLoop.makeCompletedFuture {
            let sniff = SniffHandler { [self] result, sniff in
                route(result, channel: channel, sniff: sniff, destination: destination, hostHint: hostHint)
            }
            try channel.pipeline.syncOperations.addHandler(sniff)
        }
    }

    private func route(_ result: SniffResult, channel: Channel, sniff: SniffHandler,
                       destination: IPEndpoint, hostHint: String?) {
        let isInternal = destination.address == config.internalAddress
        var connectionNote: String?
        if !isInternal, let rules = config.rules?.current {
            let (host, scheme, kind): (String, String, FlowKind) = switch result {
            case .tls(let hello): (hello.serverName ?? hostHint ?? destination.host, "https", .https)
            case .http: (hostHint ?? destination.host, "http", .http)
            case .connect(let target): (Self.host(of: target), "https", .https)
            case .unknown: (hostHint ?? destination.host, "tcp", .raw)
            }
            if !rules.allows(host: host, scheme: scheme) {
                RawRelay.start(downstream: channel, destination: destination, host: host, note: nil, sniff: sniff,
                               config: config, recorded: false)
                return
            }
            if let rule = rules.hostRule(.blockList, host: host, scheme: scheme) {
                refuse(channel, host: host, kind: kind, destination: destination, note: "Blocked by rule \"\(rule.name)\"", error: "Blocked by rule")
                return
            }
            if let rule = rules.hostRule(.networkConditions, host: host, scheme: scheme),
               case .networkConditions(let profile) = rule.action {
                if profile.dropAll {
                    refuse(channel, host: host, kind: kind, destination: destination,
                           note: "Dropped by Network Conditions \"\(rule.name)\"", error: "Dropped by Network Conditions")
                    return
                }
                try? channel.pipeline.syncOperations.addHandler(ThrottleHandler(profile: profile), position: .first)
                connectionNote = "Throttled: \(rule.name)"
            }
        }
        switch result {
        case .tls(let hello):
            let host = hello.serverName ?? hostHint ?? destination.host
            if isInternal {
                serveInternal(channel: channel, sniff: sniff, tlsHost: destination.host)
            } else if config.pinning.isPinned(host) {
                RawRelay.start(downstream: channel, destination: destination, host: host,
                               note: Self.join("Pinned: not decrypted", connectionNote), sniff: sniff, config: config)
            } else if let reason = config.bypassReason(host) {
                RawRelay.start(downstream: channel, destination: destination, host: host,
                               note: Self.join(reason, connectionNote), sniff: sniff, config: config, kind: .https)
            } else if upstreamALPN(for: hello.alpn).isEmpty {
                RawRelay.start(downstream: channel, destination: destination, host: host,
                               note: Self.join("HTTP/2-only client: not decrypted", connectionNote), sniff: sniff, config: config, kind: .https)
            } else {
                intercept(channel: channel, sniff: sniff, destination: destination, host: host, hello: hello,
                          connectionNote: connectionNote)
            }
        case .http:
            if isInternal {
                serveInternal(channel: channel, sniff: sniff, tlsHost: nil)
                return
            }
            let host = hostHint ?? destination.host
            let dial: HTTPProxySession.Dialer = { [config] loop in
                config.connector.connect(to: destination, on: loop) { $0.eventLoop.makeSucceededVoidFuture() }
            }
            do {
                try config.reaper?.track(channel)
                try HTTPProxySession.install(on: channel, config: config, destination: destination, scheme: "http",
                                             defaultHost: host, preconnected: nil, dial: dial, connectionNote: connectionNote)
                sniff.release()
            } catch {
                channel.close(promise: nil)
            }
        case .connect(let target):
            // The client's own proxy is the destination: pass the CONNECT and the tunnel through to it untouched.
            RawRelay.start(downstream: channel, destination: destination, host: Self.host(of: target),
                           note: Self.join("Through the app's proxy at \(destination)", connectionNote), sniff: sniff,
                           config: config, kind: .https)
        case .unknown:
            RawRelay.start(downstream: channel, destination: destination, host: hostHint ?? destination.host,
                           note: connectionNote, sniff: sniff, config: config)
        }
    }

    /// Closes a connection a rule refused, recording it as failed.
    private func refuse(_ channel: Channel, host: String, kind: FlowKind, destination: IPEndpoint, note: String, error: String) {
        var record = FlowRecord(kind: kind, host: host, ip: destination.host, port: Int(destination.port))
        record.state = .failed
        record.endedAt = Date()
        record.note = note
        record.error = error
        config.sink.record(record)
        channel.close(promise: nil)
    }

    /// "host" from a CONNECT target "host:port" or "[v6]:port".
    static func host(of target: String) -> String {
        if target.hasPrefix("["), let end = target.firstIndex(of: "]") { return String(target[target.index(after: target.startIndex)..<end]) }
        if let colon = target.lastIndex(of: ":") { return String(target[..<colon]) }
        return target
    }

    private static func join(_ a: String, _ b: String?) -> String { b.map { "\(a) · \($0)" } ?? a }

    private func serveInternal(channel: Channel, sniff: SniffHandler, tlsHost: String?) {
        do {
            let ops = channel.pipeline.syncOperations
            if let tlsHost {
                try ops.addHandler(NIOSSLServerHandler(context: config.ca.serverContext(for: tlsHost, alpn: ["http/1.1"])))
            }
            try ops.addHandler(HTTPResponseEncoder())
            try ops.addHandler(ByteToMessageHandler(HTTPRequestDecoder()))
            try ops.addHandler(InternalSiteHandler(ca: config.ca))
            sniff.release()
        } catch {
            channel.close(promise: nil)
        }
    }

    /// Connects to `destination` over TLS offering `alpn`; the future carries the protocol the server chose.
    private func dialTLS(_ destination: IPEndpoint, sni: String?, alpn: [String],
                         on loop: EventLoop) -> EventLoopFuture<(Channel, String?)> {
        let context: NIOSSLContext
        do { context = try upstreamContext(alpn: alpn) } catch { return loop.makeFailedFuture(error) }
        let handshake = loop.makePromise(of: String?.self)
        let timeout = loop.scheduleTask(in: .seconds(10)) { handshake.fail(ChannelError.connectTimeout(.seconds(10))) }
        handshake.futureResult.whenComplete { _ in timeout.cancel() }
        let connected = config.connector.connect(to: destination, on: loop) { ch in
            ch.eventLoop.makeCompletedFuture {
                let tls = try NIOSSLClientHandler(context: context, serverHostname: sni.flatMap(Self.validSNI))
                try ch.pipeline.syncOperations.addHandler(tls)
                try ch.pipeline.syncOperations.addHandler(HandshakeWaiter(promise: handshake))
            }
        }
        connected.whenFailure { handshake.fail($0) }
        return connected.flatMap { ch in
            handshake.futureResult.map { (ch, $0) }.flatMapErrorThrowing { error in
                ch.close(promise: nil)
                throw error
            }
        }
    }

    /// MITM: connect upstream TLS first so real TLS errors surface, then terminate the client's TLS
    /// with the protocol the server chose (HTTP/2 or HTTP/1.1).
    private func intercept(channel: Channel, sniff: SniffHandler, destination: IPEndpoint,
                           host: String, hello: ClientHelloParser.Hello, connectionNote: String?) {
        let started = Date()
        let sni = hello.serverName
        let dial: HTTPProxySession.Dialer = { [self] loop in
            dialTLS(destination, sni: sni, alpn: ["http/1.1"], on: loop).map { $0.0 }
        }
        dialTLS(destination, sni: sni, alpn: upstreamALPN(for: hello.alpn), on: channel.eventLoop).whenComplete { [self, config] result in
            switch result {
            case .failure(let error):
                var record = FlowRecord(kind: .https, host: host, ip: destination.host, port: Int(destination.port))
                record.state = .failed
                record.endedAt = Date()
                record.error = "\(FlowRecord.upstreamTLSPrefix): \(error)"
                config.sink.record(record)
                channel.close(promise: nil)
            case .success(let (upstream, negotiated)):
                let h2 = negotiated == "h2"
                guard channel.isActive else {
                    // The client gave up while the upstream dial was in flight.
                    upstream.close(promise: nil)
                    return
                }
                do {
                    let clientALPN = h2 ? ["h2"] : hello.alpn.contains("http/1.1") ? ["http/1.1"] : []
                    let ctx = try config.ca.serverContext(for: host, alpn: clientALPN)
                    let ops = channel.pipeline.syncOperations
                    try config.reaper?.track(channel)
                    try ops.addHandler(NIOSSLServerHandler(context: ctx))
                    try ops.addHandler(ClientHandshakeWatcher { outcome in
                        switch outcome {
                        case .success:
                            config.pinning.recordSuccess(host)
                        case .failure(let error):
                            upstream.close(promise: nil)
                            let tlsFailure = Self.isTLSFailure(error)
                            if tlsFailure { config.pinning.recordFailure(host) }
                            var record = FlowRecord(kind: .https, host: host, ip: destination.host, port: Int(destination.port))
                            record.state = .failed
                            record.endedAt = Date()
                            record.connectMs = Date().timeIntervalSince(started) * 1000
                            record.error = tlsFailure
                                ? "\(FlowRecord.clientRejectedPrefix) (\(error)). The CA is not trusted or the app pins certificates."
                                : "Client closed the connection during the TLS handshake"
                            config.sink.record(record)
                        }
                    })
                    if h2 {
                        try installH2(on: channel, upstream: upstream, destination: destination, host: host, sni: sni,
                                      connectionNote: connectionNote)
                    } else {
                        try HTTPProxySession.install(on: channel, config: config, destination: destination, scheme: "https",
                                                     defaultHost: host, preconnected: upstream, dial: dial, connectionNote: connectionNote)
                    }
                    sniff.release()
                } catch {
                    upstream.close(promise: nil)
                    channel.close(promise: nil)
                }
            }
        }
    }

    /// Serves HTTP/2 to the client: every client stream gets its own session and upstream stream.
    private func installH2(on channel: Channel, upstream: Channel, destination: IPEndpoint, host: String, sni: String?,
                           connectionNote: String?) throws {
        let shared = H2Upstream { [self] loop in
            dialTLS(destination, sni: sni, alpn: ["h2"], on: loop).flatMapThrowing { ch, proto in
                guard proto == "h2" else {
                    ch.close(promise: nil)
                    throw H2Error.serverRefusedH2
                }
                return ch
            }
        }
        try shared.adopt(upstream)
        channel.closeFuture.whenComplete { _ in shared.close() }
        let streamDial: HTTPProxySession.Dialer = { loop in shared.openStream(on: loop) }
        try channel.pipeline.syncOperations.addHandler(ClientEOFCloser())
        _ = try channel.pipeline.syncOperations.configureHTTP2Pipeline(
            mode: .server, connectionConfiguration: .init(), streamConfiguration: .init()
        ) { [config] stream in
            stream.eventLoop.makeCompletedFuture {
                try stream.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTP1ServerCodec())
                try HTTPProxySession.install(on: stream, config: config, destination: destination, scheme: "https",
                                             defaultHost: host, framing: .h2Stream, preconnected: nil, dial: streamDial,
                                             connectionNote: connectionNote)
            }
        }
    }

    /// Client channels allow half-closure; an HTTP/2 client that sends FIN is done with the connection.
    final class ClientEOFCloser: ChannelInboundHandler, Sendable {
        typealias InboundIn = NIOAny
        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if let e = event as? ChannelEvent, case .inputClosed = e { context.close(promise: nil) }
            context.fireUserInboundEventTriggered(event)
        }
    }

    enum H2Error: Error, CustomStringConvertible {
        case serverRefusedH2
        var description: String { "the server no longer offers HTTP/2" }
    }

    /// A certificate alert, or an iOS client hanging up mid-handshake and retrying with a fallback, means the client
    /// rejected our certificate. Resets and other alerts say nothing about the certificate.
    static func isTLSFailure(_ error: Error) -> Bool {
        switch error {
        case let e as NIOSSLError:
            guard case .handshakeFailed = e else { return false }
        case is BoringSSLError: break
        default: return false
        }
        return describesRejection(String(describing: error))
    }

    static func describesRejection(_ handshakeError: String) -> Bool {
        let text = handshakeError.uppercased()
        return ["CERTIFICATE", "UNKNOWN_CA", "EOF DURING HANDSHAKE", "INAPPROPRIATE_FALLBACK"].contains { text.contains($0) }
    }

    /// NIOSSL rejects IP literals as SNI; only send real hostnames.
    private static func validSNI(_ name: String) -> String? {
        name.isEmpty || IPAddressBytes(name) != nil ? nil : name
    }
}
