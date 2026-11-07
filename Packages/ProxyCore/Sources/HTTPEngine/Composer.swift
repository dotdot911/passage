import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import ProxyModel

/// Sends a request built in the app's Compose screen and records it like any other flow.
/// The head and body are written byte for byte as composed (HTTP/1.1), plus `Host`/`Content-Length` when missing.
public enum Composer {
    public static let note = "Sent from Compose"

    /// Starts sending and returns immediately; the outcome arrives through `sink`.
    /// - Parameters:
    ///   - flowID: id of the flow to record (its request body file, if any, already holds `body`).
    ///   - body: the request body, or nil.
    ///   - tls: upstream TLS settings (system trust store in production).
    public static func send(flowID: UUID, request: ComposedRequest, body: Data?, tls: TLSConfiguration,
                            sink: FlowSink, group: EventLoopGroup, timeout: TimeAmount = .seconds(60)) {
        var record = FlowRecord(id: flowID, kind: request.url.lowercased().hasPrefix("https") ? .https : .http,
                                host: "", ip: "", port: 0)
        record.method = request.method.uppercased()
        record.url = request.url
        record.note = note
        record.requestHeaders = request.headers
        record.requestBytes = body?.count ?? 0

        let target: ComposedRequest.Target
        do {
            target = try request.target()
        } catch {
            record.host = URLComponents(string: request.url)?.host ?? request.url
            record.state = .failed
            record.error = error.description
            record.endedAt = Date()
            sink.record(record)
            return
        }
        record.kind = target.isHTTPS ? .https : .http
        record.host = target.host
        record.port = target.port
        record.requestHeaders = request.wireHeaders(target: target, bodyLength: body?.count ?? 0)
        sink.record(record)

        let loop = group.next()
        let exchange = Exchange(record: record, sink: sink)
        let head = serializeHead(method: record.method!, target: target.requestTarget, headers: record.requestHeaders)

        loop.scheduleTask(in: timeout) { exchange.fail("Timed out after \(timeout.nanoseconds / 1_000_000_000) s") }
        let method = HTTPMethod(rawValue: record.method!)
        // Pipeline: [TLS] → gate → response decoder → recorder. The decoder sees the request head (it must know
        // about HEAD requests); the gate drops it, and the composed bytes are written below the decoder, untouched.
        // Happy Eyeballs may initialize several channels, so each gets its own gate and only the winner's is used.
        UpstreamDialer.dial(UpstreamTarget(target), tls: tls, on: loop) { ch in
            let ops = ch.pipeline.syncOperations
            try ops.addHandler(RequestHeadGate())
            try ops.addHandler(ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .dropBytes)))
            try ops.addHandler(ResponseRecorder(exchange: exchange))
        }
            .whenComplete { result in
                switch result {
                case .success(let channel):
                    exchange.connected(channel)
                    channel.write(HTTPClientRequestPart.head(HTTPRequestHead(version: .http1_1, method: method, uri: target.requestTarget)),
                                  promise: nil)
                    var buffer = channel.allocator.buffer(capacity: head.count + (body?.count ?? 0))
                    buffer.writeBytes(head)
                    if let body { buffer.writeBytes(body) }
                    do {
                        try channel.pipeline.syncOperations.handler(type: RequestHeadGate.self).writeRaw(buffer)
                    } catch {
                        exchange.fail("\(error)")
                    }
                case .failure(let error):
                    exchange.fail("Connect failed: \(error)")
                }
            }
    }

    /// `METHOD target HTTP/1.1`, the headers in order, and the blank line.
    static func serializeHead(method: String, target: String, headers: [HeaderField]) -> [UInt8] {
        var text = "\(method) \(target) HTTP/1.1\r\n"
        for h in headers { text += "\(h.name): \(h.value)\r\n" }
        return Array((text + "\r\n").utf8)
    }

    /// State of one send; touched only on its event loop.
    final class Exchange: @unchecked Sendable {
        var record: FlowRecord
        let sink: FlowSink
        let started = Date()
        var channel: Channel?
        var responseBody: BodySink?
        var done = false

        init(record: FlowRecord, sink: FlowSink) { self.record = record; self.sink = sink }

        func connected(_ channel: Channel) {
            guard !done else { channel.close(promise: nil); return }
            self.channel = channel
            record.connectMs = Date().timeIntervalSince(started) * 1000
            if let ip = channel.remoteAddress?.ipAddress { record.ip = ip }
            sink.record(record)
        }

        func head(_ head: HTTPResponseHead) {
            guard !done else { return }
            record.statusCode = Int(head.status.code)
            record.responseHeaders = head.headers.map { HeaderField(name: $0.name, value: $0.value) }
            record.ttfbMs = Date().timeIntervalSince(started) * 1000
            responseBody = sink.bodySink(flowID: record.id, side: .response)
            sink.record(record)
        }

        func body(_ buffer: ByteBuffer) {
            guard !done else { return }
            record.responseBytes += buffer.readableBytes
            responseBody?.append(Array(buffer.readableBytesView))
        }

        func complete() { finish(.completed, error: nil) }
        func fail(_ error: String) { finish(.failed, error: error) }

        private func finish(_ state: FlowState, error: String?) {
            guard !done else { return }
            done = true
            record.state = state
            record.error = error
            record.endedAt = Date()
            responseBody?.finish()
            sink.record(record)
            channel?.close(promise: nil)
        }
    }

    /// Swallows HTTP request parts (only the decoder needs them) and writes raw bytes towards the socket.
    final class RequestHeadGate: ChannelOutboundHandler, @unchecked Sendable {
        typealias OutboundIn = HTTPClientRequestPart
        typealias OutboundOut = ByteBuffer
        private var context: ChannelHandlerContext?

        func handlerAdded(context: ChannelHandlerContext) { self.context = context }
        func handlerRemoved(context: ChannelHandlerContext) { self.context = nil }

        func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
            promise?.succeed(())
        }

        /// Call on the channel's event loop.
        func writeRaw(_ buffer: ByteBuffer) {
            guard let context else { return }
            context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
        }
    }

    final class ResponseRecorder: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = HTTPClientResponsePart
        let exchange: Exchange
        init(exchange: Exchange) { self.exchange = exchange }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let head):
                // Interim responses (100 Continue) are followed by the real one.
                if head.status.code >= 100 && head.status.code < 200 && head.status != .switchingProtocols { return }
                exchange.head(head)
            case .body(let buffer): exchange.body(buffer)
            case .end: exchange.complete()
            }
        }

        func channelInactive(context: ChannelHandlerContext) {
            exchange.fail(exchange.record.statusCode == nil ? "Server closed the connection before responding"
                                                            : "Server closed the connection mid-response")
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            exchange.fail("\(error)")
            context.close(promise: nil)
        }
    }
}
