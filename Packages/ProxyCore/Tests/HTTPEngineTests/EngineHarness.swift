import CertKit
import Foundation
import HTTPEngine
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import ProxyModel
import TestSupport

/// Upstream HTTP server: answers "hello <uri>" (optionally over TLS).
final class HelloHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private var head: HTTPRequestHead?
    private var body = ""
    /// When set, the server closes the connection this long after answering (an idle keep-alive timeout).
    private let closeIdleAfter: TimeAmount?
    init(closeIdleAfter: TimeAmount? = nil) { self.closeIdleAfter = closeIdleAfter }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h): head = h; body = ""
        case .body(let b): body += String(buffer: b)
        case .end:
            let text = "hello \(head!.uri)" + (body.isEmpty ? "" : " body=\(body)")
            var headers = HTTPHeaders()
            headers.add(name: "content-length", value: "\(text.utf8.count)")
            headers.add(name: "x-upstream", value: "yes")
            let keepAlive = head!.isKeepAlive
            let channel = context.channel
            if !keepAlive { headers.add(name: "connection", value: "close") }
            context.write(wrapOutboundOut(.head(.init(version: .http1_1, status: .ok, headers: headers))), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(context.channel.allocator.buffer(string: text)))), promise: nil)
            let idle = closeIdleAfter
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
                if !keepAlive { channel.close(promise: nil) }
                else if let idle { channel.eventLoop.scheduleTask(in: idle) { channel.close(promise: nil) } }
            }
        }
    }
}

/// Echoes raw bytes back (for the non-HTTP relay test).
final class EchoHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { context.writeAndFlush(data, promise: nil) }
}

enum Harness {
    static let group = MultiThreadedEventLoopGroup.singleton
    static let destination = IPEndpoint(address: [93, 184, 216, 34], port: 443)

    static func helloServer(tls: NIOSSLContext? = nil, closeIdleAfter: TimeAmount? = nil) async throws -> Channel {
        try await ServerBootstrap(group: group)
            .childChannelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    if let tls { try ch.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls)) }
                    try ch.pipeline.syncOperations.configureHTTPServerPipeline()
                    try ch.pipeline.syncOperations.addHandler(HelloHandler(closeIdleAfter: closeIdleAfter))
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
    }

    static func echoServer() async throws -> Channel {
        try await ServerBootstrap(group: group)
            .childChannelInitializer { ch in
                ch.eventLoop.makeCompletedFuture { try ch.pipeline.syncOperations.addHandler(EchoHandler()) }
            }
            .bind(host: "127.0.0.1", port: 0).get()
    }

    /// A local listener whose accepted sockets are handed to the router as if they came from the tunnel.
    static func proxyListener(router: FlowRouter, destination: IPEndpoint, hostHint: String?) async throws -> Channel {
        try await ServerBootstrap(group: group)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { ch in router.install(on: ch, destination: destination, hostHint: hostHint) }
            .bind(host: "127.0.0.1", port: 0).get()
    }

    /// Connects to `address`, optionally speaks TLS (trusting `trust`, sending `sni`),
    /// writes `request`, and returns every byte received until the server closes or 2 s pass.
    static func exchange(_ address: SocketAddress, request: String, tlsTrust: NIOSSLCertificate? = nil,
                         sni: String? = nil, verifyHostname: Bool = true, alpn: [String] = ["http/1.1"],
                         timeout: TimeAmount = .seconds(2)) async throws -> String {
        let collected = group.next().makePromise(of: String.self)
        let collector = Collector(promise: collected)
        var tlsContext: NIOSSLContext?
        if let tlsTrust {
            var c = TLSConfiguration.makeClientConfiguration()
            c.trustRoots = .certificates([tlsTrust])
            c.applicationProtocols = alpn
            if !verifyHostname { c.certificateVerification = .noHostnameVerification }
            tlsContext = try NIOSSLContext(configuration: c)
        }
        let ch = try await ClientBootstrap(group: group)
            .channelInitializer { [tlsContext] ch in
                ch.eventLoop.makeCompletedFuture {
                    if let tlsContext {
                        try ch.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: tlsContext, serverHostname: sni))
                    }
                    try ch.pipeline.syncOperations.addHandler(collector)
                }
            }
            .connect(to: address).get()
        try await ch.writeAndFlush(ch.allocator.buffer(string: request)).get()
        ch.eventLoop.scheduleTask(in: timeout) { ch.close(promise: nil) }
        return try await collected.futureResult.get()
    }

    /// Sends `first`, waits `delay`, sends `second` on the same connection, and collects until close or timeout.
    static func exchangeTwice(_ address: SocketAddress, first: String, second: String, delay: TimeAmount,
                              timeout: TimeAmount = .seconds(2)) async throws -> String {
        let collected = group.next().makePromise(of: String.self)
        let ch = try await ClientBootstrap(group: group)
            .channelInitializer { ch in
                ch.eventLoop.makeCompletedFuture { try ch.pipeline.syncOperations.addHandler(Collector(promise: collected)) }
            }
            .connect(to: address).get()
        try await ch.writeAndFlush(ch.allocator.buffer(string: first)).get()
        ch.eventLoop.scheduleTask(in: delay) { ch.writeAndFlush(ch.allocator.buffer(string: second), promise: nil) }
        ch.eventLoop.scheduleTask(in: timeout) { ch.close(promise: nil) }
        return try await collected.futureResult.get()
    }

    final class Collector: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        let promise: EventLoopPromise<String>
        var text = ""
        init(promise: EventLoopPromise<String>) { self.promise = promise }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) { text += String(buffer: unwrapInboundIn(data)) }
        func channelInactive(context: ChannelHandlerContext) { promise.succeed(text) }
        func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
    }
}

/// Answers the first request with 101 Switching Protocols, then echoes raw bytes.
final class UpgradeEchoHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private var upgraded = false
    private var head = ""
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = unwrapInboundIn(data)
        if upgraded { context.writeAndFlush(NIOAny(buf), promise: nil); return }
        head += buf.readString(length: buf.readableBytes) ?? ""
        guard let end = head.range(of: "\r\n\r\n") else { return }
        upgraded = true
        let rest = String(head[end.upperBound...])
        context.write(NIOAny(context.channel.allocator.buffer(string:
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")), promise: nil)
        if !rest.isEmpty { context.write(NIOAny(context.channel.allocator.buffer(string: rest)), promise: nil) }
        context.flush()
    }
}

extension Harness {
    static func upgradeServer() async throws -> Channel {
        try await ServerBootstrap(group: group)
            .childChannelInitializer { ch in
                ch.eventLoop.makeCompletedFuture { try ch.pipeline.syncOperations.addHandler(UpgradeEchoHandler()) }
            }
            .bind(host: "127.0.0.1", port: 0).get()
    }
}
