import CertKit
import Foundation
@testable import HTTPEngine
import NIOCore
import NIOPosix
import ProxyModel
import Rules
import Testing
import TestSupport

/// Answers every request with a fixed raw response and remembers what it received.
final class FixedResponder: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let received: Received
    let response: String
    init(received: Received, response: String) { self.received = received; self.response = response }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let all = received.append(String(buffer: unwrapInboundIn(data)))
        guard all.hasSuffix("\r\n\r\n") else { return }
        context.writeAndFlush(NIOAny(context.channel.allocator.buffer(string: response))).whenComplete { _ in context.close(promise: nil) }
    }
}

final class Paused: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [BreakpointItem] = []
    func add(_ item: BreakpointItem) { lock.withLock { items.append(item) } }
    var first: BreakpointItem? { lock.withLock { items.first } }
}

@Suite(.serialized) struct RuleEngineTests {
    let ca = try! CertificateAuthority.generate()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rules-\(UUID().uuidString)")

    func engine(_ rules: [Rule], timeout: TimeInterval = 300, onPause: @escaping @Sendable (BreakpointItem) -> Void = { _ in }) -> RuleEngine {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return RuleEngine(rules: RuleSet(rules: rules, enabledTools: Set(RuleTool.allCases)), rulesDirectory: dir,
                          breakpoints: BreakpointCenter(directory: dir.appendingPathComponent("bp"), timeout: timeout, onPause: onPause))
    }

    func proxy(_ engine: RuleEngine, sink: MemorySink, upstream: SocketAddress, hostHint: String? = "api.test") async throws -> Channel {
        let config = EngineConfig(ca: ca, sink: sink, connector: LocalConnector(target: upstream), rules: engine)
        return try await Harness.proxyListener(router: try FlowRouter(config: config),
                                               destination: IPEndpoint(address: [10, 0, 0, 1], port: 80), hostHint: hostHint)
    }

    func get(_ proxy: Channel, _ path: String = "/a", extra: String = "", body: String = "") async throws -> String {
        let length = body.isEmpty ? "" : "Content-Length: \(body.utf8.count)\r\n"
        return try await Harness.exchange(proxy.localAddress!, request:
            "\(body.isEmpty ? "GET" : "POST") \(path) HTTP/1.1\r\nHost: api.test\r\n\(extra)\(length)Connection: close\r\n\r\n\(body)")
    }

    func rule(_ tool: RuleTool, _ pattern: String, _ action: RuleAction) -> Rule {
        Rule(tool: tool, name: tool.rawValue, match: URLMatch(pattern: pattern), action: action)
    }

    func rule(_ tool: RuleTool, _ action: RuleAction) -> Rule { rule(tool, "http://api.test/*", action) }

    @Test func mapLocalAnswersFromTheFile() async throws {
        let upstream = try await Harness.helloServer()
        let local = rule(.mapLocal, .mapLocal(status: 201, headers: [HeaderField(name: "X-Mock", value: "1"),
                                                                   HeaderField(name: "Content-Length", value: "999")]))
        let missing = rule(.mapLocal, "http://api.test/missing", .mapLocal(status: 200, headers: []))
        let e = engine([missing, local])
        try Data("mocked".utf8).write(to: dir.appendingPathComponent("\(local.id.uuidString).body"))
        let sink = MemorySink()
        let p = try await proxy(e, sink: sink, upstream: upstream.localAddress!)

        let reply = try await get(p)
        #expect(reply.hasPrefix("HTTP/1.1 201 Created"))
        #expect(reply.contains("X-Mock: 1") && reply.contains("content-length: 6") && reply.hasSuffix("mocked"))
        #expect(try await get(p, "/missing").hasPrefix("HTTP/1.1 500"))
        #expect(await sink.waitFor { $0.contains { $0.note == "Map Local: mapLocal" && $0.statusCode == 201 } })
    }

    @Test func mapRemoteSendsToAnotherServer() async throws {
        let original = try await Harness.helloServer()
        let other = try await Harness.helloServer()
        let port = other.localAddress!.port!
        let keep = rule(.mapRemote, "http://api.test/keep*", .mapRemote(target: "http://127.0.0.1:\(port)"))
        let replace = rule(.mapRemote, "http://api.test/swap*", .mapRemote(target: "http://127.0.0.1:\(port)/new"))
        let sink = MemorySink()
        let p = try await proxy(engine([keep, replace]), sink: sink, upstream: original.localAddress!)

        #expect(try await get(p, "/keep/x?q=1").hasSuffix("hello /keep/x?q=1"))
        #expect(try await get(p, "/swap/y?q=2").hasSuffix("hello /new?q=2"))
        #expect(await sink.waitFor { $0.contains { $0.note == "Mapped to http://127.0.0.1:\(port)/new?q=2" && $0.url == "http://api.test/swap/y?q=2" } })
    }

    @Test func mapRemoteHonorsDNSSpoofing() async throws {
        let original = try await Harness.helloServer()
        let other = try await Harness.helloServer()
        let port = other.localAddress!.port!
        let map = rule(.mapRemote, "http://api.test/*", .mapRemote(target: "http://staging.invalid:\(port)"))
        let spoof = rule(.dnsSpoof, "staging.invalid", .dnsSpoof(addresses: ["127.0.0.1"]))
        let sink = MemorySink()
        let p = try await proxy(engine([map, spoof]), sink: sink, upstream: original.localAddress!)

        #expect(try await get(p, "/x").hasSuffix("hello /x"))
        #expect(await sink.waitFor { $0.contains { $0.note?.contains("staging.invalid → 127.0.0.1") == true } })
    }

    @Test func blockByURLAndByHost() async throws {
        let upstream = try await Harness.helloServer()
        let sink = MemorySink()
        let byURL = try await proxy(engine([rule(.blockList, "http://api.test/ads/*", .block)]), sink: sink, upstream: upstream.localAddress!)
        #expect(try await get(byURL, "/ads/1") == "")
        #expect(try await get(byURL, "/ok").hasSuffix("hello /ok"))

        let byHost = try await proxy(engine([rule(.blockList, "api.test", .block)]), sink: sink, upstream: upstream.localAddress!)
        #expect(try await get(byHost, "/ok") == "")
        #expect(await sink.waitFor { flows in flows.filter { $0.error == "Blocked by rule" }.count == 2 })
    }

    @Test func noCachingRewritesBothDirections() async throws {
        let received = Received()
        let server = try await ServerBootstrap(group: Harness.group)
            .childChannelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    try ch.pipeline.syncOperations.addHandler(FixedResponder(received: received, response:
                        "HTTP/1.1 200 OK\r\nETag: \"v1\"\r\nLast-Modified: x\r\nCache-Control: max-age=60\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"))
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        let sink = MemorySink()
        let p = try await proxy(engine([rule(.noCaching, "*", .noCaching)]), sink: sink, upstream: server.localAddress!)
        let reply = try await get(p, extra: "If-None-Match: \"v1\"\r\n")
        let sent = received.value.lowercased()
        #expect(!sent.contains("if-none-match") && sent.contains("cache-control: no-cache") && sent.contains("pragma: no-cache"))
        #expect(!reply.lowercased().contains("etag") && !reply.lowercased().contains("last-modified"))
        #expect(reply.lowercased().contains("cache-control: no-store") && reply.hasSuffix("ok"))
    }

    @Test func requestBreakpointEditsAndExecutes() async throws {
        let upstream = try await Harness.helloServer()
        let paused = Paused()
        let e = engine([rule(.breakpoint, .breakpoint(request: true, response: false))]) { paused.add($0) }
        let sink = MemorySink()
        let p = try await proxy(e, sink: sink, upstream: upstream.localAddress!)

        async let reply = get(p, "/orig", body: "before")
        for _ in 0..<200 where paused.first == nil { try await Task.sleep(for: .milliseconds(10)) }
        let item = try #require(paused.first)
        #expect(item.phase == .request && item.method == "POST" && item.url == "http://api.test/orig")
        #expect(try String(contentsOf: e.breakpoints.bodyURL(item.id), encoding: .utf8) == "before")
        #expect(sink.all.first { $0.id == item.flowID }?.state == .paused)

        try Data("after!".utf8).write(to: e.breakpoints.bodyURL(item.id))
        var headers = item.headers
        headers.append(HeaderField(name: "X-Edited", value: "yes"))
        #expect(e.breakpoints.resolve(id: item.id, decision: .execute(
            BreakpointEdit(method: "PUT", url: "http://api.test/edited", status: nil, headers: headers))))

        #expect(try await reply.hasSuffix("hello /edited body=after!"))
        #expect(await sink.waitFor { $0.contains { $0.method == "PUT" && $0.note == "Edited at breakpoint" && $0.state == .completed } })
    }

    @Test func clientLeavingWhilePausedDropsTheBreakpoint() async throws {
        let upstream = try await Harness.helloServer()
        let paused = Paused()
        let dropped = Paused()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let center = BreakpointCenter(directory: dir.appendingPathComponent("bp"), onPause: { paused.add($0) },
                                      onDrop: { id in dropped.add(BreakpointItem(flowID: id, phase: .request, ruleName: "", method: "", url: "", headers: [])) })
        let e = RuleEngine(rules: RuleSet(rules: [rule(.breakpoint, .breakpoint(request: true, response: false))], enabledTools: Set(RuleTool.allCases)),
                           rulesDirectory: dir, breakpoints: center)
        let sink = MemorySink()
        let p = try await proxy(e, sink: sink, upstream: upstream.localAddress!)

        // Reset rather than half-close, the way a client that gives up actually leaves.
        let client = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton).connect(to: p.localAddress!).get()
        try await (client as! SocketOptionProvider).setSoLinger(linger(l_onoff: 1, l_linger: 0)).get()
        try await client.writeAndFlush(client.allocator.buffer(string: "GET /gone HTTP/1.1\r\nHost: api.test\r\nX-Probe: 1\r\n\r\n")).get()
        for _ in 0..<200 where paused.first == nil { try await Task.sleep(for: .milliseconds(10)) }
        let item = try #require(paused.first)
        try await client.close()
        for _ in 0..<200 where dropped.first == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(dropped.first?.flowID == item.id)
        #expect(center.pending().isEmpty)
        #expect(!e.breakpoints.resolve(id: item.id, decision: .abort))
        #expect(await sink.waitFor { $0.contains {
            $0.id == item.flowID && $0.state == .failed && $0.requestHeaders.contains { $0.name == "X-Probe" }
        } })
    }

    @Test func requestBreakpointAbortAndTimeout() async throws {
        let upstream = try await Harness.helloServer()
        let paused = Paused()
        let aborting = engine([rule(.breakpoint, .breakpoint(request: true, response: false))]) { paused.add($0) }
        let sink = MemorySink()
        let p = try await proxy(aborting, sink: sink, upstream: upstream.localAddress!)
        async let aborted = get(p, "/x")
        for _ in 0..<200 where paused.first == nil { try await Task.sleep(for: .milliseconds(10)) }
        aborting.breakpoints.resolve(id: try #require(paused.first).id, decision: .abort)
        #expect(try await aborted == "")
        #expect(await sink.waitFor { $0.contains { $0.error == "Aborted at breakpoint" } })

        let timing = engine([rule(.breakpoint, .breakpoint(request: true, response: false))], timeout: 0.2)
        let q = try await proxy(timing, sink: sink, upstream: upstream.localAddress!)
        #expect(try await get(q, "/late").hasSuffix("hello /late"))
        #expect(await sink.waitFor { $0.contains { $0.note == "Breakpoint timed out" } })
    }

    @Test func responseBreakpointEditsStatusAndBody() async throws {
        let upstream = try await Harness.helloServer()
        let paused = Paused()
        let e = engine([rule(.breakpoint, .breakpoint(request: false, response: true))]) { paused.add($0) }
        let sink = MemorySink()
        let p = try await proxy(e, sink: sink, upstream: upstream.localAddress!)

        async let reply = get(p, "/r")
        for _ in 0..<200 where paused.first == nil { try await Task.sleep(for: .milliseconds(10)) }
        let item = try #require(paused.first)
        #expect(item.phase == .response && item.status == 200)
        #expect(try String(contentsOf: e.breakpoints.bodyURL(item.id), encoding: .utf8) == "hello /r")
        try Data("short and stout".utf8).write(to: e.breakpoints.bodyURL(item.id))
        e.breakpoints.resolve(id: item.id, decision: .execute(BreakpointEdit(method: "GET", url: item.url, status: 418,
                                                                             headers: [HeaderField(name: "X-Tea", value: "pot")])))
        let text = try await reply
        #expect(text.hasPrefix("HTTP/1.1 418"))
        #expect(text.contains("X-Tea: pot") && text.contains("Content-Length: 15") && text.hasSuffix("short and stout"))
        #expect(await sink.waitFor { $0.contains { $0.statusCode == 418 && $0.responseBytes == 15 && $0.state == .completed } })
    }

    @Test func networkConditionsDropAll() async throws {
        let upstream = try await Harness.helloServer()
        let sink = MemorySink()
        let p = try await proxy(engine([rule(.networkConditions, "api.test", .networkConditions(NetworkProfile(dropAll: true)))]),
                                sink: sink, upstream: upstream.localAddress!)
        #expect(try await get(p) == "")
        #expect(await sink.waitFor { $0.contains { $0.error == "Dropped by Network Conditions" } })
    }

    @Test func allowListSkipsOtherHostsWithoutRecording() async throws {
        let upstream = try await Harness.helloServer()
        let sink = MemorySink()
        let p = try await proxy(engine([rule(.allowList, "only.test", .allow)]), sink: sink, upstream: upstream.localAddress!)
        #expect(try await get(p).hasSuffix("hello /a"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(sink.all.isEmpty)
    }
}

@Suite struct HandshakeRejectionTests {
    @Test func iOSHangUpsAndCertificateAlertsCountAsRejection() {
        let rejected = [
            "handshakeFailed(NIOSSL.BoringSSLError.sslError([Error:  EOF during handshake]))",
            "handshakeFailed(NIOSSL.BoringSSLError.sslError([Error: 268435613 error:1000009d:SSL routines:OPENSSL_internal:INAPPROPRIATE_FALLBACK]))",
            "handshakeFailed(NIOSSL.BoringSSLError.sslError([Error: 268436502 error:10000416:SSL routines:OPENSSL_internal:SSLV3_ALERT_CERTIFICATE_UNKNOWN]))",
            "handshakeFailed(NIOSSL.BoringSSLError.sslError([Error: 268436528 error:10000418:SSL routines:OPENSSL_internal:TLSV1_ALERT_UNKNOWN_CA]))",
        ]
        let other = [
            "handshakeFailed(NIOSSL.BoringSSLError.sslError([Error: 268436496 error:10000410:SSL routines:OPENSSL_internal:SSLV3_ALERT_HANDSHAKE_FAILURE]))",
            "handshakeFailed(NIOSSL.BoringSSLError.sslError([Error: 268436546 error:1000045a:SSL routines:OPENSSL_internal:TLSV1_ALERT_USER_CANCELLED]))",
        ]
        #expect(rejected.allSatisfy(FlowRouter.describesRejection))
        #expect(!other.contains(where: FlowRouter.describesRejection))
    }
}
