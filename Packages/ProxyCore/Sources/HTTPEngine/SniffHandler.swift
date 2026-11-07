import NIOCore

/// What the first bytes of a client connection look like.
public enum SniffResult: Equatable, Sendable {
    case tls(ClientHelloParser.Hello)
    case http
    /// The client takes the destination for an HTTP proxy and asks it for a tunnel to `target` ("host:port").
    case connect(target: String)
    case unknown
}

/// Buffers the first client bytes until the protocol is known, then hands the
/// connection to `FlowRouter`. Buffered bytes are replayed by `release()`.
final class SniffHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    static let maxBytes = 16 * 1024 + 5
    static let timeout = TimeAmount.milliseconds(300)
    private static let methods = ["GET ", "POST ", "PUT ", "HEAD ", "DELETE ", "PATCH ", "OPTIONS ", "TRACE ", "CONNECT "]

    private var buffer: ByteBuffer?
    private var decided = false
    private var context: ChannelHandlerContext?
    private var timer: Scheduled<Void>?
    private let decide: (SniffResult, SniffHandler) -> Void

    init(decide: @escaping (SniffResult, SniffHandler) -> Void) { self.decide = decide }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        // Server-speaks-first protocols (SMTP, SSH banners...) send nothing: give up waiting.
        timer = context.eventLoop.scheduleTask(in: Self.timeout) { [weak self] in self?.finish(.unknown) }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        if buffer == nil { buffer = incoming } else { buffer!.writeBuffer(&incoming) }
        guard !decided else { return }
        let bytes = Array(buffer!.readableBytesView)
        switch ClientHelloParser.parse(bytes) {
        case .hello(let hello): finish(.tls(hello))
        case .needMoreData where bytes.count < Self.maxBytes: return
        case .needMoreData: finish(.unknown)
        case .notTLS:
            let text = String(decoding: bytes.prefix(8), as: UTF8.self)
            if text.hasPrefix("CONNECT ") {
                guard let line = Self.firstLine(bytes) else {
                    if bytes.count >= Self.maxBytes { finish(.unknown) }
                    return
                }
                let parts = line.split(separator: " ")
                finish(parts.count >= 2 ? .connect(target: String(parts[1])) : .unknown)
            } else if Self.methods.contains(where: { text.hasPrefix($0) }) { finish(.http) }
            else if bytes.count < 8 && Self.methods.contains(where: { $0.hasPrefix(text) }) { return }
            else { finish(.unknown) }
        }
    }

    /// The bytes before the first CRLF, or nil until one arrives.
    static func firstLine(_ bytes: [UInt8]) -> String? {
        guard let end = bytes.indices.first(where: { $0 + 1 < bytes.count && bytes[$0] == 13 && bytes[$0 + 1] == 10 }) else { return nil }
        return String(decoding: bytes[..<end], as: UTF8.self)
    }

    func channelInactive(context: ChannelHandlerContext) {
        timer?.cancel()
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        timer?.cancel()
        self.context = nil
    }

    private func finish(_ result: SniffResult) {
        guard !decided, let context else { return }
        decided = true
        timer?.cancel()
        // Hold further reads until the router has set up the rest of the pipeline.
        context.channel.setOption(ChannelOptions.autoRead, value: false).whenComplete { _ in }
        decide(result, self)
    }

    /// Replays buffered bytes into the handlers added after this one, then removes itself.
    func release() {
        guard let context else { return }
        if let buffer, buffer.readableBytes > 0 { context.fireChannelRead(wrapInboundOut(buffer)) }
        buffer = nil
        context.fireChannelReadComplete()
        let channel = context.channel
        context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
        channel.setOption(ChannelOptions.autoRead, value: true).whenSuccess { channel.read() }
    }
}
