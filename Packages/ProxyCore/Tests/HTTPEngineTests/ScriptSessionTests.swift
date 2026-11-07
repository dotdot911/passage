import CertKit
import Foundation
@testable import HTTPEngine
import NIOCore
import NIOPosix
import ProxyModel
import Rules
import Scripting
import Testing
import TestSupport

@Suite(.serialized) struct ScriptSessionTests {
    let ca = try! CertificateAuthority.generate()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scripts-\(UUID().uuidString)")

    /// A proxy whose only rule is one script on `http://api.test/*`.
    func proxy(_ code: String, request: Bool = true, response: Bool = false, sink: MemorySink, upstream: SocketAddress,
               recordBodies: Bool = true) async throws -> Channel {
        let rule = Rule(tool: .script, name: "s", match: URLMatch(pattern: "http://api.test/*"),
                        action: .script(request: request, response: response))
        let runner = ScriptRunner()
        runner.load([ScriptSource(id: rule.id, name: rule.name, code: code)])
        let engine = RuleEngine(rules: RuleSet(rules: [rule], enabledTools: [.script]), rulesDirectory: dir,
                                breakpoints: BreakpointCenter(directory: dir.appendingPathComponent("bp")), scripts: runner)
        let config = EngineConfig(ca: ca, sink: sink, connector: LocalConnector(target: upstream),
                                  recordBodies: { recordBodies }, rules: engine)
        return try await Harness.proxyListener(router: try FlowRouter(config: config),
                                               destination: IPEndpoint(address: [10, 0, 0, 1], port: 80), hostHint: "api.test")
    }

    func send(_ proxy: Channel, _ path: String = "/a", body: String = "") async throws -> String {
        let length = body.isEmpty ? "" : "Content-Length: \(body.utf8.count)\r\n"
        return try await Harness.exchange(proxy.localAddress!, request:
            "\(body.isEmpty ? "GET" : "POST") \(path) HTTP/1.1\r\nHost: api.test\r\n\(length)Connection: close\r\n\r\n\(body)")
    }

    func fixedServer(_ received: Received, _ response: String) async throws -> Channel {
        try await ServerBootstrap(group: Harness.group)
            .childChannelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    try ch.pipeline.syncOperations.addHandler(FixedResponder(received: received, response: response))
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
    }

    @Test func editsTheRequest() async throws {
        let upstream = try await Harness.helloServer()
        let sink = MemorySink()
        let p = try await proxy("""
            function handle(f) { f.request.url = f.request.url.replace(/[/]a$/, '/b'); f.request.body = f.request.body.toUpperCase() + '!' }
            """, sink: sink, upstream: upstream.localAddress!)
        #expect(try await send(p, body: "data").hasSuffix("hello /b body=DATA!"))
        #expect(await sink.waitFor { $0.contains { $0.url == "http://api.test/b" && $0.note == "Script \"s\": edited request" && $0.requestBytes == 5 } })
    }

    @Test func addsAHeaderToAGet() async throws {
        let received = Received()
        let server = try await fixedServer(received, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
        let p = try await proxy("function handle(f) { f.request.headers['X-Script'] = crypto.md5('a') }",
                                sink: MemorySink(), upstream: server.localAddress!)
        #expect(try await send(p).hasSuffix("ok"))
        #expect(received.value.contains("X-Script: 0cc175b9c0f1b6a831c399e269772661"))
        #expect(!received.value.lowercased().contains("content-length"))
    }

    @Test func editsTheResponseUsingTheRequestBody() async throws {
        let upstream = try await Harness.helloServer()
        let sink = MemorySink()
        let p = try await proxy("""
            function handle(f) {
              if (f.phase === 'request') return;
              f.response.status = 202;
              f.response.headers['X-Seen'] = f.request.body;
              f.response.body = { was: f.response.body };
            }
            """, request: true, response: true, sink: sink, upstream: upstream.localAddress!)
        let reply = try await send(p, body: "abc")
        #expect(reply.hasPrefix("HTTP/1.1 202 Accepted"))
        #expect(reply.contains("X-Seen: abc") && reply.contains("Content-Length: \(#"{"was":"hello /a body=abc"}"#.utf8.count)"))
        #expect(reply.hasSuffix(#"{"was":"hello /a body=abc"}"#))
        #expect(await sink.waitFor { $0.contains { $0.statusCode == 202 && $0.note == "Script \"s\" · Script \"s\": edited response" && $0.state == .completed } })
    }

    @Test func heldResponseSurvivesTheUpstreamClosing() async throws {
        let received = Received()
        let server = try await fixedServer(received, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
        let sink = MemorySink()
        let p = try await proxy("""
            function handle(f) { const end = Date.now() + 300; while (Date.now() < end) {} f.response.body += "!" }
            """, request: false, response: true, sink: sink, upstream: server.localAddress!)
        #expect(try await send(p).hasSuffix("ok!"))
        #expect(await sink.waitFor { $0.contains { $0.state == .completed && $0.note == "Script \"s\": edited response" } })
    }

    @Test func mockSkipsTheServer() async throws {
        let received = Received()
        let server = try await fixedServer(received, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
        let sink = MemorySink()
        let p = try await proxy("function handle(f) { f.response = { status: 201, headers: { 'X-Mock': '1' }, body: 'mocked' } }",
                                sink: sink, upstream: server.localAddress!)
        let reply = try await send(p)
        #expect(reply.hasPrefix("HTTP/1.1 201") && reply.contains("X-Mock: 1") && reply.hasSuffix("mocked"))
        #expect(received.value.isEmpty)
        #expect(await sink.waitFor { $0.contains { $0.note == "Mocked by script \"s\"" && $0.statusCode == 201 } })
    }

    @Test func abortClosesTheConnection() async throws {
        let upstream = try await Harness.helloServer()
        let sink = MemorySink()
        let p = try await proxy("function handle(f) { f.abort() }", sink: sink, upstream: upstream.localAddress!)
        #expect(try await send(p) == "")
        #expect(await sink.waitFor { $0.contains { $0.state == .failed && $0.error == "Aborted by script" } })
    }

    @Test func brokenScriptLetsTrafficThrough() async throws {
        let upstream = try await Harness.helloServer()
        let sink = MemorySink()
        let p = try await proxy("function handle(f) { throw new Error('nope') }", request: true, response: true,
                                sink: sink, upstream: upstream.localAddress!)
        #expect(try await send(p, body: "x").hasSuffix("hello /a body=x"))
        #expect(await sink.waitFor { $0.contains { $0.note == "Script error: Error: nope (line 1) · Script error: Error: nope (line 1)" } })
    }

    @Test func lowMemorySkipsScripts() async throws {
        let upstream = try await Harness.helloServer()
        let sink = MemorySink()
        let p = try await proxy("function handle(f) { f.abort() }", sink: sink, upstream: upstream.localAddress!, recordBodies: false)
        #expect(try await send(p).hasSuffix("hello /a"))
        #expect(await sink.waitFor { $0.contains { $0.note == "Script skipped: low memory" && $0.state == .completed } })
    }

    @Test func largeBodySkipsTheScript() async throws {
        let upstream = try await Harness.helloServer()
        let sink = MemorySink()
        let p = try await proxy("function handle(f) { f.abort() }", sink: sink, upstream: upstream.localAddress!)
        let big = String(repeating: "x", count: BreakpointCenter.maxBodyBytes + 1)
        let reply = try await Harness.exchange(p.localAddress!, request:
            "POST /a HTTP/1.1\r\nHost: api.test\r\nContent-Length: \(big.utf8.count)\r\nConnection: close\r\n\r\n\(big)", timeout: .seconds(10))
        #expect(reply.contains("hello /a body=xxx"))
        #expect(await sink.waitFor { $0.contains { $0.note == "Script skipped: body over 10 MB" } })
    }
}
