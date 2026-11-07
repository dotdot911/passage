import CertKit
import Foundation
import HTTPEngine
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOHTTP2
import NIOPosix
import NIOSSL
import ProxyModel
import Testing
import TestSupport

/// Counts the server's open connections, so a test can see the proxy hang up upstream.
final class ConnectionCounter: ChannelInboundHandler, Sendable {
    typealias InboundIn = NIOAny
    let open = NIOLockedValueBox(0)
    func channelActive(context: ChannelHandlerContext) {
        open.withLockedValue { $0 += 1 }
        context.fireChannelActive()
    }
    func channelInactive(context: ChannelHandlerContext) {
        open.withLockedValue { $0 -= 1 }
        context.fireChannelInactive()
    }
    func waitUntilClosed() async -> Bool {
        for _ in 0..<100 {
            if open.withLockedValue({ $0 }) == 0 { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}

@Suite struct ConnectionCloseTests {
    let ca = try! CertificateAuthority.generate()
    let realCA = try! CertificateAuthority.generate(commonName: "Real Server CA")

    func proxy(to upstream: Channel) async throws -> (Channel, NIOSSLCertificate) {
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.trustRoots = .certificates([try NIOSSLCertificate(bytes: realCA.rootDER(), format: .der)])
        let cfg = EngineConfig(ca: ca, sink: MemorySink(), connector: LocalConnector(target: upstream.localAddress!), upstreamTLS: tls)
        let proxy = try await Harness.proxyListener(router: try FlowRouter(config: cfg), destination: Harness.destination, hostHint: nil)
        return (proxy, try NIOSSLCertificate(bytes: ca.rootDER(), format: .der))
    }

    @Test func http2UpstreamClosesWhenTheClientLeaves() async throws {
        let counter = ConnectionCounter()
        let tls = try realCA.serverContext(for: "api.test", alpn: ["h2"])
        let upstream = try await ServerBootstrap(group: Harness.group)
            .childChannelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    try ch.pipeline.syncOperations.addHandler(counter)
                    try ch.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls))
                    _ = try ch.pipeline.syncOperations.configureHTTP2Pipeline(mode: .server, connectionConfiguration: .init(), streamConfiguration: .init()) { stream in
                        stream.eventLoop.makeCompletedFuture {
                            try stream.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTP1ServerCodec())
                            try stream.pipeline.syncOperations.addHandler(H2HelloHandler())
                        }
                    }
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        let (proxy, trust) = try await proxy(to: upstream)

        var c = TLSConfiguration.makeClientConfiguration()
        c.trustRoots = .certificates([trust])
        c.applicationProtocols = ["h2"]
        let context = try NIOSSLContext(configuration: c)
        let muxPromise = Harness.group.next().makePromise(of: NIOHTTP2Handler.StreamMultiplexer.self)
        // HTTP/2 handlers go in before the handshake so the server preface is never dropped.
        let client = try await ClientBootstrap(group: Harness.group)
            .channelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    try ch.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: context, serverHostname: "api.test"))
                    muxPromise.succeed(try ch.pipeline.syncOperations.configureHTTP2Pipeline(mode: .client, connectionConfiguration: .init(), streamConfiguration: .init()) { $0.eventLoop.makeSucceededVoidFuture() })
                }
            }
            .connect(to: proxy.localAddress!).get()
        let mux = try await muxPromise.futureResult.get()
        let done = client.eventLoop.makePromise(of: H2Response.self)
        let stream = client.eventLoop.makePromise(of: Channel.self)
        mux.createStreamChannel(promise: stream) { s in
            s.eventLoop.makeCompletedFuture {
                try s.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https))
                try s.pipeline.syncOperations.addHandler(H2ResponseCollector(promise: done))
            }
        }
        let s = try await stream.futureResult.get()
        s.write(HTTPClientRequestPart.head(.init(version: .http2, method: .GET, uri: "/one", headers: ["host": "api.test"])), promise: nil)
        s.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
        #expect(try await done.futureResult.get().body == "h2 hello /one")

        try await client.close()
        #expect(await counter.waitUntilClosed())
    }

    @Test func keepAliveUpstreamClosesWhenTheClientLeaves() async throws {
        let counter = ConnectionCounter()
        let tls = try realCA.serverContext(for: "api.test", alpn: ["http/1.1"])
        let upstream = try await ServerBootstrap(group: Harness.group)
            .childChannelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    try ch.pipeline.syncOperations.addHandler(counter)
                    try ch.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls))
                    try ch.pipeline.syncOperations.configureHTTPServerPipeline()
                    try ch.pipeline.syncOperations.addHandler(HelloHandler())
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        let (proxy, trust) = try await proxy(to: upstream)

        let response = try await Harness.exchange(proxy.localAddress!, request: "GET /one HTTP/1.1\r\nHost: api.test\r\n\r\n",
                                                  tlsTrust: trust, sni: "api.test", timeout: .milliseconds(200))
        #expect(response.contains("hello /one"))
        #expect(await counter.waitUntilClosed())
    }
}
