import CertKit
import Foundation
import HTTPEngine
import NIOCore
import NIOHTTP1
import NIOHTTP2
import NIOPosix
import NIOSSL
import NIOTLS
import ProxyModel
import Rules
import Testing
import TestSupport

/// Answers like `HelloHandler`, plus gRPC-style trailers when the request asks for them (`te: trailers`).
final class H2HelloHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private var head: HTTPRequestHead?
    private var body = ""

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h): head = h; body = ""
        case .body(let b): body += String(buffer: b)
        case .end:
            let text = "h2 hello \(head!.uri)" + (body.isEmpty ? "" : " body=\(body)")
            var headers = HTTPHeaders()
            headers.add(name: "content-length", value: "\(text.utf8.count)")
            headers.add(name: "x-version", value: "\(head!.version.major)")
            context.write(wrapOutboundOut(.head(.init(version: head!.version, status: .ok, headers: headers))), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(context.channel.allocator.buffer(string: text)))), promise: nil)
            let trailers: HTTPHeaders? = head!.headers.first(name: "te") == "trailers" ? ["grpc-status": "0"] : nil
            context.writeAndFlush(wrapOutboundOut(.end(trailers)), promise: nil)
        }
    }
}

/// One response as seen by the test client.
struct H2Response {
    var status: Int
    var headers: HTTPHeaders
    var body: String
    var trailers: HTTPHeaders?
}

/// Collects one stream's response.
final class H2ResponseCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    let promise: EventLoopPromise<H2Response>
    private var response = H2Response(status: 0, headers: [:], body: "")
    init(promise: EventLoopPromise<H2Response>) { self.promise = promise }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h): response.status = Int(h.status.code); response.headers = h.headers
        case .body(let b): response.body += String(buffer: b)
        case .end(let t): response.trailers = t; promise.succeed(response)
        }
    }
    func channelInactive(context: ChannelHandlerContext) { promise.fail(ChannelError.eof) }
    func errorCaught(context: ChannelHandlerContext, error: Error) { promise.fail(error) }
}

extension Harness {
    /// A TLS server offering `alpn`; HTTP/2 connections get `H2HelloHandler` per stream, HTTP/1.1 ones `HelloHandler`.
    static func h2Server(ca: CertificateAuthority, host: String, alpn: [String] = ["h2", "http/1.1"]) async throws -> Channel {
        let tls = try ca.serverContext(for: host, alpn: alpn)
        return try await ServerBootstrap(group: group)
            .childChannelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    try ch.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls))
                }.flatMap {
                    ch.configureHTTP2SecureUpgrade(h2ChannelConfigurator: { ch in
                        ch.configureHTTP2Pipeline(mode: .server) { stream in
                            stream.eventLoop.makeCompletedFuture {
                                try stream.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTP1ServerCodec())
                                try stream.pipeline.syncOperations.addHandler(H2HelloHandler())
                            }
                        }.map { _ in }
                    }, http1ChannelConfigurator: { ch in
                        ch.eventLoop.makeCompletedFuture {
                            try ch.pipeline.syncOperations.configureHTTPServerPipeline()
                            try ch.pipeline.syncOperations.addHandler(HelloHandler())
                        }
                    })
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
    }

    /// Opens one TLS connection offering `alpn` and sends every request on its own HTTP/2 stream, concurrently.
    /// - Returns: the protocol the proxy chose and the responses in request order.
    static func h2Requests(_ address: SocketAddress, trust: NIOSSLCertificate, sni: String, alpn: [String] = ["h2", "http/1.1"],
                           requests: [(method: HTTPMethod, path: String, headers: HTTPHeaders, body: String?)]) async throws
        -> (String?, [H2Response]) {
        var c = TLSConfiguration.makeClientConfiguration()
        c.trustRoots = .certificates([trust])
        c.applicationProtocols = alpn
        let context = try NIOSSLContext(configuration: c)
        let negotiated = group.next().makePromise(of: String?.self)
        let ch = try await ClientBootstrap(group: group)
            .channelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    try ch.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: context, serverHostname: sni))
                    try ch.pipeline.syncOperations.addHandler(ALPNWatcher(promise: negotiated))
                }
            }
            .connect(to: address).get()
        defer { ch.close(promise: nil) }
        let proto = try await negotiated.futureResult.get()
        guard proto == "h2" else { return (proto, []) }
        let mux = try await ch.eventLoop.submit {
            try ch.pipeline.syncOperations.configureHTTP2Pipeline(
                mode: .client, connectionConfiguration: .init(), streamConfiguration: .init()
            ) { $0.eventLoop.makeSucceededVoidFuture() }
        }.get()
        var futures: [EventLoopFuture<H2Response>] = []
        for r in requests {
            let done = ch.eventLoop.makePromise(of: H2Response.self)
            let stream = ch.eventLoop.makePromise(of: Channel.self)
            mux.createStreamChannel(promise: stream) { s in
                s.eventLoop.makeCompletedFuture {
                    try s.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https))
                    try s.pipeline.syncOperations.addHandler(H2ResponseCollector(promise: done))
                }
            }
            let s = try await stream.futureResult.get()
            var headers = r.headers
            headers.replaceOrAdd(name: "host", value: sni)
            if let body = r.body { headers.add(name: "content-length", value: "\(body.utf8.count)") }
            s.write(HTTPClientRequestPart.head(.init(version: .http2, method: r.method, uri: r.path, headers: headers)), promise: nil)
            if let body = r.body { s.write(HTTPClientRequestPart.body(.byteBuffer(s.allocator.buffer(string: body))), promise: nil) }
            s.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
            futures.append(done.futureResult)
        }
        var out: [H2Response] = []
        for f in futures { out.append(try await f.get()) }
        return (proto, out)
    }

    final class ALPNWatcher: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = NIOAny
        let promise: EventLoopPromise<String?>
        init(promise: EventLoopPromise<String?>) { self.promise = promise }
        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if let e = event as? TLSUserEvent, case .handshakeCompleted(let p) = e { promise.succeed(p) }
            context.fireUserInboundEventTriggered(event)
        }
        func errorCaught(context: ChannelHandlerContext, error: Error) { promise.fail(error) }
        func channelInactive(context: ChannelHandlerContext) { promise.fail(ChannelError.eof) }
    }
}

@Suite struct HTTP2Tests {
    let ca = try! CertificateAuthority.generate()
    let realCA = try! CertificateAuthority.generate(commonName: "Real Server CA")

    func setup(serverALPN: [String] = ["h2", "http/1.1"], http2: Bool = true, rules: RuleEngine? = nil)
        async throws -> (proxy: Channel, sink: MemorySink, trust: NIOSSLCertificate) {
        let upstream = try await Harness.h2Server(ca: realCA, host: "api.test", alpn: serverALPN)
        let sink = MemorySink()
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.trustRoots = .certificates([try NIOSSLCertificate(bytes: realCA.rootDER(), format: .der)])
        let cfg = EngineConfig(ca: ca, sink: sink, connector: LocalConnector(target: upstream.localAddress!), upstreamTLS: tls,
                               rules: rules, http2Enabled: { http2 })
        let router = try FlowRouter(config: cfg)
        let proxy = try await Harness.proxyListener(router: router, destination: Harness.destination, hostHint: nil)
        return (proxy, sink, try NIOSSLCertificate(bytes: ca.rootDER(), format: .der))
    }

    @Test func http2StreamsAreProxiedAndRecorded() async throws {
        let (proxy, sink, trust) = try await setup()
        let (proto, responses) = try await Harness.h2Requests(proxy.localAddress!, trust: trust, sni: "api.test", requests: [
            (.GET, "/one", [:], nil),
            (.POST, "/two?x=1", ["content-type": "text/plain"], "abc"),
            (.GET, "/three", [:], nil),
        ])
        #expect(proto == "h2")
        #expect(responses.map(\.body) == ["h2 hello /one", "h2 hello /two?x=1 body=abc", "h2 hello /three"])
        #expect(responses.allSatisfy { $0.headers.first(name: "x-version") == "2" })
        #expect(await sink.waitFor { flows in flows.filter { $0.state == .completed }.count == 3 })
        let post = try #require(sink.all.first { $0.method == "POST" })
        #expect(post.httpVersion == "HTTP/2")
        #expect(post.url == "https://api.test/two?x=1")
        #expect(post.host == "api.test")
        #expect(post.statusCode == 200)
        #expect(sink.body(post.id, .request) == "abc")
        #expect(sink.body(post.id, .response) == "h2 hello /two?x=1 body=abc")
    }

    @Test func trailersPassThrough() async throws {
        let (proxy, _, trust) = try await setup()
        let (_, responses) = try await Harness.h2Requests(proxy.localAddress!, trust: trust, sni: "api.test", requests: [
            (.POST, "/pkg.Service/Call", ["content-type": "application/grpc", "te": "trailers"], "\u{0}\u{0}\u{0}\u{0}\u{0}"),
        ])
        #expect(responses.first?.trailers?.first(name: "grpc-status") == "0")
    }

    @Test func serverWithoutH2MakesBothSidesHTTP1() async throws {
        let (proxy, sink, trust) = try await setup(serverALPN: ["http/1.1"])
        let (proto, _) = try await Harness.h2Requests(proxy.localAddress!, trust: trust, sni: "api.test", requests: [])
        #expect(proto == "http/1.1")
        let reply = try await Harness.exchange(proxy.localAddress!, request: "GET /h1 HTTP/1.1\r\nHost: api.test\r\nConnection: close\r\n\r\n",
                                               tlsTrust: trust, sni: "api.test", alpn: ["h2", "http/1.1"])
        #expect(reply.hasSuffix("hello /h1"))
        let flow = try #require(await sink.waitFor { $0.contains { $0.state == .completed } } ? sink.all.first { $0.state == .completed } : nil)
        #expect(flow.httpVersion == "HTTP/1.1")
    }

    @Test func http2SwitchOffKeepsHTTP1() async throws {
        let (proxy, _, trust) = try await setup(http2: false)
        let (proto, _) = try await Harness.h2Requests(proxy.localAddress!, trust: trust, sni: "api.test", requests: [])
        #expect(proto == "http/1.1")
    }

    @Test func h2OnlyClientIsDecrypted() async throws {
        let (proxy, sink, trust) = try await setup()
        let (proto, responses) = try await Harness.h2Requests(proxy.localAddress!, trust: trust, sni: "api.test", alpn: ["h2"],
                                                              requests: [(.GET, "/only", [:], nil)])
        #expect(proto == "h2")
        #expect(responses.first?.body == "h2 hello /only")
        #expect(await sink.waitFor { $0.contains { $0.url == "https://api.test/only" && $0.state == .completed } })
    }

    @Test func mapRemoteFromAnH2StreamToAnHTTP1Server() async throws {
        let plain = try await Harness.helloServer()
        let port = (plain.localAddress?.port)!
        let rule = Rule(tool: .mapRemote, name: "to h1", match: URLMatch(pattern: "https://api.test/mapped*"),
                        action: .mapRemote(target: "http://127.0.0.1:\(port)/elsewhere"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("h2-\(UUID().uuidString)")
        let engine = RuleEngine(rules: RuleSet(rules: [rule], enabledTools: [.mapRemote]), rulesDirectory: dir,
                                breakpoints: BreakpointCenter(directory: dir.appendingPathComponent("bp")))
        let (proxy, sink, trust) = try await setup(rules: engine)
        let (_, responses) = try await Harness.h2Requests(proxy.localAddress!, trust: trust, sni: "api.test", requests: [
            (.GET, "/mapped", [:], nil),
            (.GET, "/direct", [:], nil),
        ])
        #expect(responses.map(\.body) == ["hello /elsewhere", "h2 hello /direct"])
        #expect(await sink.waitFor { flows in flows.filter { $0.state == .completed }.count == 2 })
        #expect(sink.all.first { $0.url == "https://api.test/mapped" }?.note?.contains("Mapped to") == true)
    }
}
