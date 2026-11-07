import CertKit
import Foundation
@testable import HTTPEngine
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import ProxyModel
import TestSupport
import Testing

/// Thread-safe text buffer filled by the capture server.
final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func append(_ s: String) -> String { lock.withLock { text += s; return text } }
    var value: String { lock.withLock { text } }
}

/// Records the raw bytes it receives, then answers 201 with a JSON body and closes.
final class CaptureHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let received: Received
    init(received: Received) { self.received = received }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let text = String(buffer: unwrapInboundIn(data))
        let all = received.append(text)
        guard let end = all.range(of: "\r\n\r\n") else { return }
        let length = all[..<end.lowerBound].split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        guard all.utf8.count - all[..<end.upperBound].utf8.count >= length else { return }
        let reply = "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: 11\r\nConnection: close\r\n\r\n{\"ok\":true}"
        context.writeAndFlush(NIOAny(context.channel.allocator.buffer(string: reply))).whenComplete { _ in context.close(promise: nil) }
    }
}

@Suite struct ComposerTests {
    func captureServer(tls: NIOSSLContext? = nil) async throws -> (Channel, Received) {
        let received = Received()
        let server = try await ServerBootstrap(group: Harness.group)
            .childChannelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    if let tls { try ch.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls)) }
                    try ch.pipeline.syncOperations.addHandler(CaptureHandler(received: received))
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        return (server, received)
    }

    @Test func sendsExactBytesAndRecordsTheResponse() async throws {
        let (server, received) = try await captureServer()
        let port = server.localAddress!.port!
        let sink = MemorySink()
        let id = UUID()
        let request = ComposedRequest(method: "post", url: "http://127.0.0.1:\(port)/v1/items?x=1",
                                      headers: [HeaderField(name: "X-B", value: "2"), HeaderField(name: "x-b", value: "3")])
        Composer.send(flowID: id, request: request, body: Data("hello".utf8), tls: .makeClientConfiguration(),
                      sink: sink, group: Harness.group)

        #expect(await sink.waitFor { $0.first { $0.id == id }?.state == .completed })
        #expect(received.value ==
                "POST /v1/items?x=1 HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nX-B: 2\r\nx-b: 3\r\nContent-Length: 5\r\n\r\nhello")
        let flow = try #require(sink.all.first { $0.id == id })
        #expect(flow.statusCode == 201)
        #expect(flow.kind == .http && flow.host == "127.0.0.1" && flow.ip == "127.0.0.1" && flow.port == port)
        #expect(flow.note == Composer.note)
        #expect(flow.requestBytes == 5)
        #expect(flow.responseHeaders.value(for: "content-type") == "application/json")
        #expect(sink.body(id, .response) == #"{"ok":true}"#)
        #expect(flow.connectMs != nil && flow.ttfbMs != nil)
    }

    @Test func sendsOverTLS() async throws {
        let ca = try CertificateAuthority.generate(commonName: "Compose Test CA")
        let (server, received) = try await captureServer(tls: try ca.serverContext(for: "localhost", alpn: ["http/1.1"]))
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.trustRoots = .certificates([try NIOSSLCertificate(bytes: ca.rootDER(), format: .der)])
        let sink = MemorySink()
        let id = UUID()
        Composer.send(flowID: id, request: ComposedRequest(url: "https://localhost:\(server.localAddress!.port!)/secure"),
                      body: nil, tls: tls, sink: sink, group: Harness.group)

        #expect(await sink.waitFor { $0.first { $0.id == id }?.state == .completed })
        #expect(received.value.hasPrefix("GET /secure HTTP/1.1\r\nHost: localhost:"))
        #expect(sink.all.first { $0.id == id }?.kind == .https)
    }

    @Test func connectFailureAndBadURLAreRecordedAsFailed() async throws {
        let closed = try await Harness.echoServer()
        let port = closed.localAddress!.port!
        try await closed.close()
        let sink = MemorySink()
        let refused = UUID(), bad = UUID()
        Composer.send(flowID: refused, request: ComposedRequest(url: "http://127.0.0.1:\(port)/"), body: nil,
                      tls: .makeClientConfiguration(), sink: sink, group: Harness.group)
        Composer.send(flowID: bad, request: ComposedRequest(url: "ftp://x/"), body: nil,
                      tls: .makeClientConfiguration(), sink: sink, group: Harness.group)

        #expect(await sink.waitFor { flows in
            flows.first { $0.id == refused }?.state == .failed && flows.first { $0.id == bad }?.state == .failed
        })
        #expect(sink.all.first { $0.id == refused }?.error?.hasPrefix("Connect failed") == true)
        #expect(sink.all.first { $0.id == bad }?.error?.contains("ftp") == true)
    }

    @Test func timesOutWhenTheServerNeverAnswers() async throws {
        let silent = try await Harness.echoServer() // echoes the request back, which is not a valid response
        let sink = MemorySink()
        let id = UUID()
        Composer.send(flowID: id, request: ComposedRequest(url: "http://127.0.0.1:\(silent.localAddress!.port!)/"), body: nil,
                      tls: .makeClientConfiguration(), sink: sink, group: Harness.group, timeout: .milliseconds(300))
        #expect(await sink.waitFor { $0.first { $0.id == id }?.state == .failed })
    }
}
