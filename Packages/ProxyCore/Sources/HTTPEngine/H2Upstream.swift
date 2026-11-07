import NIOCore
import NIOHTTP1
import NIOHTTP2

/// The HTTP/2 connection to the server shared by every stream of one client connection.
/// Streams are opened on demand; a closed connection (or one that sent GOAWAY) is redialled.
/// Confined to the client connection's event loop.
final class H2Upstream: @unchecked Sendable {
    /// Opens a TLS connection on which the server agreed to `h2`, with no HTTP/2 handlers yet.
    typealias Dialer = @Sendable (EventLoop) -> EventLoopFuture<Channel>

    private let redial: Dialer
    private var multiplexer: NIOHTTP2Handler.StreamMultiplexer?
    private var channel: Channel?
    private var connecting: EventLoopFuture<NIOHTTP2Handler.StreamMultiplexer>?
    private var usable = false

    init(redial: @escaping Dialer) { self.redial = redial }

    /// Adds the HTTP/2 client handlers to a connection that just negotiated `h2`.
    func adopt(_ ch: Channel) throws {
        var connection = NIOHTTP2Handler.ConnectionConfiguration()
        connection.initialSettings = nioDefaultSettings + [HTTP2Setting(parameter: .enablePush, value: 0)]
        let mux = try ch.pipeline.syncOperations.configureHTTP2Pipeline(
            mode: .client, connectionConfiguration: connection, streamConfiguration: .init()
        ) { $0.eventLoop.makeSucceededVoidFuture() }
        try ch.pipeline.syncOperations.addHandler(GoAwayWatcher { [weak self, weak ch] in
            if let ch, self?.channel === ch { self?.usable = false }
        })
        ch.closeFuture.whenComplete { [weak self, weak ch] _ in
            if let ch, self?.channel === ch { self?.usable = false }
        }
        multiplexer = mux
        channel = ch
        usable = true
    }

    /// A new stream speaking HTTP/1-style parts through `HTTP2FramePayloadToHTTP1ClientCodec`.
    func openStream(on loop: EventLoop) -> EventLoopFuture<Channel> {
        connection(on: loop).flatMap { mux in
            let promise = loop.makePromise(of: Channel.self)
            mux.createStreamChannel(promise: promise) { stream in
                stream.eventLoop.makeCompletedFuture {
                    try stream.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https))
                }
            }
            return promise.futureResult
        }
    }

    /// Closes the connection to the server (the client connection went away).
    func close() {
        usable = false
        channel?.close(promise: nil)
    }

    private func connection(on loop: EventLoop) -> EventLoopFuture<NIOHTTP2Handler.StreamMultiplexer> {
        if usable, let multiplexer, channel?.isActive == true { return loop.makeSucceededFuture(multiplexer) }
        if let connecting { return connecting }
        let opened = redial(loop).flatMapThrowing { [self] ch in
            try adopt(ch)
            return multiplexer!
        }
        connecting = opened
        opened.whenComplete { [self] _ in connecting = nil }
        return opened
    }
}

/// Reports a GOAWAY from the server: streams already open finish, new ones need a new connection.
private final class GoAwayWatcher: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTP2Frame
    private let onGoAway: () -> Void
    init(onGoAway: @escaping () -> Void) { self.onGoAway = onGoAway }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .goAway = unwrapInboundIn(data).payload { onGoAway() }
    }
}
