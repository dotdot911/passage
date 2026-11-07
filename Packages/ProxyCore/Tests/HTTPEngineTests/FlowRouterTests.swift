import CertKit
import Foundation
import HTTPEngine
import NIOCore
import NIOPosix
import NIOSSL
import ProxyModel
import SwiftASN1
import Testing
import TestSupport

@Suite struct FlowRouterTests {
    let ca = try! CertificateAuthority.generate()

    func config(sink: MemorySink, upstream: SocketAddress, upstreamTrust: NIOSSLCertificate? = nil) -> EngineConfig {
        var tls = TLSConfiguration.makeClientConfiguration()
        if let upstreamTrust { tls.trustRoots = .certificates([upstreamTrust]) }
        return EngineConfig(ca: ca, sink: sink, connector: LocalConnector(target: upstream), upstreamTLS: tls)
    }

    @Test func plainHTTPIsForwardedAndRecorded() async throws {
        let upstream = try await Harness.helloServer()
        let sink = MemorySink()
        let router = try FlowRouter(config: config(sink: sink, upstream: upstream.localAddress!))
        let proxy = try await Harness.proxyListener(router: router, destination: .init(address: [93, 184, 216, 34], port: 80), hostHint: nil)

        let reply = try await Harness.exchange(proxy.localAddress!,
            request: "POST /a?x=1 HTTP/1.1\r\nHost: api.test\r\nContent-Length: 3\r\nConnection: close\r\n\r\nabc")

        #expect(reply.hasPrefix("HTTP/1.1 200 OK"))
        #expect(reply.hasSuffix("hello /a?x=1 body=abc"))
        let flow = try #require(sink.all.first { $0.kind == .http })
        #expect(flow.state == .completed)
        #expect(flow.method == "POST")
        #expect(flow.url == "http://api.test/a?x=1")
        #expect(flow.host == "api.test")
        #expect(flow.statusCode == 200)
        #expect(flow.requestBytes == 3)
        #expect(flow.responseHeaders.contains(HeaderField(name: "x-upstream", value: "yes")))
        #expect(sink.body(flow.id, .request) == "abc")
        #expect(sink.body(flow.id, .response) == "hello /a?x=1 body=abc")
    }

    @Test func httpsIsDecryptedWithOurCertificate() async throws {
        // The "real" server uses its own CA, which only the engine trusts.
        let realCA = try CertificateAuthority.generate(commonName: "Real Server CA")
        let upstream = try await Harness.helloServer(tls: realCA.serverContext(for: "api.test", alpn: ["http/1.1"]))
        let sink = MemorySink()
        let cfg = config(sink: sink, upstream: upstream.localAddress!,
                         upstreamTrust: try NIOSSLCertificate(bytes: realCA.rootDER(), format: .der))
        let router = try FlowRouter(config: cfg)
        let proxy = try await Harness.proxyListener(router: router, destination: Harness.destination, hostHint: nil)

        let reply = try await Harness.exchange(proxy.localAddress!,
            request: "GET /secure HTTP/1.1\r\nHost: api.test\r\nConnection: close\r\n\r\n",
            tlsTrust: try NIOSSLCertificate(bytes: ca.rootDER(), format: .der), sni: "api.test")

        #expect(reply.hasSuffix("hello /secure"))
        let flow = try #require(sink.all.first { $0.kind == .https })
        #expect(flow.url == "https://api.test/secure")
        #expect(flow.state == .completed)
        #expect(cfg.pinning.caTrusted)
    }

    @Test func clientRejectingCertificateIsRecordedAndEventuallyPinned() async throws {
        let realCA = try CertificateAuthority.generate(commonName: "Real Server CA")
        let upstream = try await Harness.helloServer(tls: realCA.serverContext(for: "pinned.test", alpn: ["http/1.1"]))
        let sink = MemorySink()
        let cfg = config(sink: sink, upstream: upstream.localAddress!,
                         upstreamTrust: try NIOSSLCertificate(bytes: realCA.rootDER(), format: .der))
        cfg.pinning.setEnabled(true)
        cfg.pinning.recordSuccess("other.test") // pretend the CA is already trusted
        let router = try FlowRouter(config: cfg)
        let proxy = try await Harness.proxyListener(router: router, destination: Harness.destination, hostHint: nil)
        // The client trusts only the real CA, exactly like an app that pins.
        let pinnedTrust = try NIOSSLCertificate(bytes: realCA.rootDER(), format: .der)
        for _ in 0..<PinningTracker.threshold {
            _ = try? await Harness.exchange(proxy.localAddress!, request: "GET / HTTP/1.1\r\nHost: pinned.test\r\n\r\n",
                                            tlsTrust: pinnedTrust, sni: "pinned.test")
        }
        #expect(await sink.waitFor { _ in cfg.pinning.isPinned("pinned.test") })
        #expect(sink.all.contains { $0.error?.contains("rejected") == true })

        // Next attempt is relayed untouched, so the pinned client talks to the real server.
        let reply = try await Harness.exchange(proxy.localAddress!,
            request: "GET /direct HTTP/1.1\r\nHost: pinned.test\r\nConnection: close\r\n\r\n",
            tlsTrust: pinnedTrust, sni: "pinned.test")
        #expect(reply.hasSuffix("hello /direct"))
        #expect(sink.all.contains { $0.kind == .raw && $0.note == "Pinned: not decrypted" })
    }

    @Test func disabledTrackerNeverPins() {
        let tracker = PinningTracker(pinned: ["known.test"])
        tracker.recordSuccess("other.test")
        for _ in 0..<PinningTracker.threshold * 2 { tracker.recordFailure("bank.test") }
        #expect(!tracker.isPinned("bank.test"))
        #expect(!tracker.isPinned("known.test"))
        tracker.setEnabled(true)
        #expect(tracker.isPinned("known.test"))
    }

    @Test func unknownProtocolIsRelayedRaw() async throws {
        let upstream = try await Harness.echoServer()
        let sink = MemorySink()
        let router = try FlowRouter(config: config(sink: sink, upstream: upstream.localAddress!))
        let proxy = try await Harness.proxyListener(router: router, destination: .init(address: [10, 0, 0, 1], port: 5222), hostHint: "chat.test")

        let reply = try await Harness.exchange(proxy.localAddress!, request: "\u{01}binary-ping", timeout: .milliseconds(300))

        #expect(reply == "\u{01}binary-ping")
        #expect(await sink.waitFor { $0.contains { $0.kind == .raw && $0.state == .completed } })
        let flow = try #require(sink.all.first { $0.kind == .raw })
        #expect(flow.host == "chat.test")
        #expect(flow.requestBytes == 12)
        #expect(flow.responseBytes == 12)
    }

    @Test func unreachableUpstreamReturns502() async throws {
        let sink = MemorySink()
        let dead = try SocketAddress(ipAddress: "127.0.0.1", port: 1)
        let router = try FlowRouter(config: config(sink: sink, upstream: dead))
        let proxy = try await Harness.proxyListener(router: router, destination: .init(address: [93, 184, 216, 34], port: 80), hostHint: nil)

        let reply = try await Harness.exchange(proxy.localAddress!, request: "GET / HTTP/1.1\r\nHost: down.test\r\n\r\n")

        #expect(reply.hasPrefix("HTTP/1.1 502 Bad Gateway"))
        #expect(sink.all.first?.state == .failed)
    }

    @Test func internalSiteServesTrustCheck() async throws {
        let sink = MemorySink()
        let router = try FlowRouter(config: config(sink: sink, upstream: try SocketAddress(ipAddress: "127.0.0.1", port: 1)))
        let proxy = try await Harness.proxyListener(router: router, destination: .init(address: [198, 18, 0, 1], port: 443), hostHint: nil)

        let reply = try await Harness.exchange(proxy.localAddress!,
            request: "GET /check HTTP/1.1\r\nHost: 198.18.0.1\r\nConnection: close\r\n\r\n",
            tlsTrust: try NIOSSLCertificate(bytes: ca.rootDER(), format: .der), sni: nil, verifyHostname: false)

        #expect(reply.contains("200 OK"))
        #expect(reply.hasSuffix("ok"))
    }
}

extension FlowRouterTests {
    @Test func pipelinedRequestsOnOneConnectionAreRecordedSeparately() async throws {
        let upstream = try await Harness.helloServer()
        let sink = MemorySink()
        let router = try FlowRouter(config: config(sink: sink, upstream: upstream.localAddress!))
        let proxy = try await Harness.proxyListener(router: router, destination: .init(address: [93, 184, 216, 34], port: 80), hostHint: nil)

        let reply = try await Harness.exchange(proxy.localAddress!, request:
            "GET /one HTTP/1.1\r\nHost: api.test\r\n\r\nGET /two HTTP/1.1\r\nHost: api.test\r\nConnection: close\r\n\r\n")

        #expect(reply.contains("hello /one"))
        #expect(reply.hasSuffix("hello /two"))
        #expect(await sink.waitFor { flows in flows.filter { $0.state == .completed }.count == 2 })
        #expect(Set(sink.all.compactMap(\.url)) == ["http://api.test/one", "http://api.test/two"])
    }
}

extension FlowRouterTests {
    @Test func upgradeSwitchesToRawRelayIncludingBytesSentWithTheRequest() async throws {
        let upstream = try await Harness.upgradeServer()
        let sink = MemorySink()
        let router = try FlowRouter(config: config(sink: sink, upstream: upstream.localAddress!))
        let proxy = try await Harness.proxyListener(router: router, destination: .init(address: [93, 184, 216, 34], port: 80), hostHint: nil)

        let reply = try await Harness.exchange(proxy.localAddress!, request:
            "GET /ws HTTP/1.1\r\nHost: api.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\nPING",
            timeout: .milliseconds(300))

        #expect(reply.hasPrefix("HTTP/1.1 101 Switching Protocols"))
        #expect(reply.hasSuffix("PING"))
        #expect(await sink.waitFor { $0.contains { $0.note?.hasPrefix("Upgraded to websocket") == true } })
        // Once the client has gone the upgraded flow must be finalized.
        #expect(await sink.waitFor { $0.contains { $0.note?.hasPrefix("Upgraded to websocket") == true && $0.state == .completed && $0.endedAt != nil } })
    }
}

extension FlowRouterTests {
    @Test func upstreamClosedWhileIdleIsRedialedForTheNextRequest() async throws {
        let upstream = try await Harness.helloServer(closeIdleAfter: .milliseconds(30))
        let sink = MemorySink()
        let router = try FlowRouter(config: config(sink: sink, upstream: upstream.localAddress!))
        let proxy = try await Harness.proxyListener(router: router, destination: .init(address: [93, 184, 216, 34], port: 80), hostHint: nil)

        let reply = try await Harness.exchangeTwice(proxy.localAddress!,
            first: "GET /one HTTP/1.1\r\nHost: api.test\r\n\r\n",
            second: "GET /two HTTP/1.1\r\nHost: api.test\r\nConnection: close\r\n\r\n",
            delay: .milliseconds(300))

        #expect(!reply.contains("502"))
        #expect(reply.contains("hello /one"))
        #expect(reply.hasSuffix("hello /two"))
    }

    @Test func http2OnlyClientIsRelayedWhenHTTP2IsOff() async throws {
        let upstream = try await Harness.echoServer()
        let sink = MemorySink()
        var cfg = config(sink: sink, upstream: upstream.localAddress!)
        cfg.http2Enabled = { false }
        let router = try FlowRouter(config: cfg)
        let proxy = try await Harness.proxyListener(router: router, destination: Harness.destination, hostHint: nil)

        _ = try? await Harness.exchange(proxy.localAddress!, request: "x",
            tlsTrust: try NIOSSLCertificate(bytes: ca.rootDER(), format: .der), sni: "grpc.test",
            alpn: ["h2"], timeout: .milliseconds(300))

        #expect(await sink.waitFor { $0.contains { 
            $0.kind == .https && $0.method == "CONNECT" && $0.statusCode == 200 && $0.url?.hasPrefix("https://grpc.test") == true
                && $0.requestHeaders == [HeaderField(name: "Host", value: "grpc.test")] && $0.note == "HTTP/2-only client: not decrypted"
        } })
        #expect(!router.config.pinning.caTrusted)
    }
}

extension FlowRouterTests {
    /// A client frame: FIN set, masked with a fixed key.
    static func maskedFrame(opcode: UInt8, _ payload: [UInt8]) -> [UInt8] {
        let key: [UInt8] = [1, 2, 3, 4]
        precondition(payload.count < 126)
        return [0x80 | opcode, 0x80 | UInt8(payload.count)] + key + payload.enumerated().map { $0.element ^ key[$0.offset % 4] }
    }

    @Test func webSocketMessagesAreRecordedInBothDirections() async throws {
        let upstream = try await Harness.upgradeServer()
        let sink = MemorySink()
        let router = try FlowRouter(config: config(sink: sink, upstream: upstream.localAddress!))
        let proxy = try await Harness.proxyListener(router: router, destination: .init(address: [93, 184, 216, 34], port: 80), hostHint: nil)

        let ch = try await ClientBootstrap(group: Harness.group).connect(to: proxy.localAddress!).get()
        try await ch.writeAndFlush(ch.allocator.buffer(string:
            "GET /ws HTTP/1.1\r\nHost: api.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")).get()
        try await Task.sleep(for: .milliseconds(100))
        // The echo server sends each frame back unchanged, so the same messages arrive as "received".
        let frames = Self.maskedFrame(opcode: 1, Array("hello".utf8)) + Self.maskedFrame(opcode: 2, [0xde, 0xad])
        try await ch.writeAndFlush(ch.allocator.buffer(bytes: frames)).get()
        #expect(await sink.waitFor { _ in sink.webSocketMessages.count == 4 })
        let messages = sink.webSocketMessages.sorted { $0.seq < $1.seq }
        #expect(messages.filter { $0.direction == .sent }.map(\.payload) == [Data("hello".utf8), Data([0xde, 0xad])])
        #expect(messages.filter { $0.direction == .received }.map(\.opcode) == [.text, .binary])
        #expect(Set(messages.map(\.seq)) == [0, 1, 2, 3])
        try await ch.close()
    }
}
