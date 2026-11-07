import Foundation
import NIOCore
import NIOPosix
import NetStack

/// Turns an lwIP `TCPConnection` into a regular NIO `Channel`.
///
/// lwIP is not a NIO transport, so each connection gets an AF_UNIX socketpair:
/// one end is pumped to/from lwIP by `PumpHandler`, the other end is returned as an
/// ordinary NIO channel that the HTTP engine treats like any accepted socket.
public enum SocketBridge {
    /// Stop reading from the engine side when this many bytes wait for lwIP.
    static let highWater = 128 * 1024
    static let lowWater = 32 * 1024

    public static func attach(
        _ conn: TCPConnection,
        stack: NetStack,
        group: EventLoopGroup,
        initializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Channel> {
        let loop = group.next()
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            return loop.makeFailedFuture(IOError(errnoCode: errno, reason: "socketpair"))
        }
        let handler = PumpHandler(conn: conn, stack: stack)
        let pump = ClientBootstrap(group: loop)
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .channelInitializer { ch in
                ch.eventLoop.makeCompletedFuture { try ch.pipeline.syncOperations.addHandler(handler) }
            }
            .withConnectedSocket(fds[0])
        let engine = ClientBootstrap(group: loop)
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .channelInitializer(initializer)
            .withConnectedSocket(fds[1])
        return pump.and(engine).map { pumpChannel, engineChannel in
            // The engine side allows half-closure, so the pump closing only reads as EOF there.
            // A reset must tear the engine channel down fully: hand it to the pump.
            handler.peer = engineChannel
            if !pumpChannel.isActive { engineChannel.close(promise: nil) }
            return engineChannel
        }.flatMapError { error in
            stack.queue.async { conn.abort() }
            // Close whichever side did come up so its fd does not leak.
            pump.whenSuccess { $0.close(promise: nil) }
            engine.whenSuccess { $0.close(promise: nil) }
            return loop.makeFailedFuture(error)
        }
    }
}

/// Lives on the pump channel's event loop; talks to `conn` only via `stack.queue`.
final class PumpHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let conn: TCPConnection
    private let stack: NetStack
    /// The engine-side channel of the socketpair. Only touch on the event loop.
    var peer: Channel?

    init(conn: TCPConnection, stack: NetStack) {
        self.conn = conn
        self.stack = stack
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        let loop = context.eventLoop
        let conn = self.conn
        let stack = self.stack
        stack.queue.async {
            conn.onData = { data in
                loop.execute {
                    var buf = channel.allocator.buffer(capacity: data.count)
                    buf.writeBytes(data)
                    channel.writeAndFlush(buf).whenSuccess {
                        stack.queue.async { conn.consumed(data.count) }
                    }
                }
            }
            conn.onRemoteClose = {
                loop.execute { channel.close(mode: .output, promise: nil) }
            }
            conn.onReset = { [weak self] _ in
                let handler = self
                loop.execute {
                    handler?.peer?.close(promise: nil)
                    channel.close(promise: nil)
                }
            }
            conn.onWritable = { [weak conn] in
                guard let conn, conn.pendingWriteBytes < SocketBridge.lowWater else { return }
                loop.execute {
                    channel.setOption(ChannelOptions.autoRead, value: true).whenSuccess { channel.read() }
                }
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let bytes = Data(unwrapInboundIn(data).readableBytesView)
        let channel = context.channel
        let conn = self.conn
        stack.queue.async {
            conn.write(bytes)
            if conn.pendingWriteBytes > SocketBridge.highWater {
                channel.eventLoop.execute {
                    channel.setOption(ChannelOptions.autoRead, value: false).whenComplete { _ in }
                }
            }
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case ChannelEvent.inputClosed = event {
            let conn = self.conn
            stack.queue.async { conn.shutdownWrite() }
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        let conn = self.conn
        stack.queue.async { conn.close() }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        let conn = self.conn
        stack.queue.async { conn.abort() }
        context.close(promise: nil)
    }
}
