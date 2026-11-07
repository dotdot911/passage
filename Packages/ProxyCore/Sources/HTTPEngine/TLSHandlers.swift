import NIOCore
import NIOSSL
import NIOTLS

/// Completes `promise` when the TLS handshake on this channel finishes (or fails), then removes itself.
final class HandshakeWaiter: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = NIOAny
    private let promise: EventLoopPromise<String?>
    private var done = false

    init(promise: EventLoopPromise<String?>) { self.promise = promise }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let e = event as? TLSUserEvent, case .handshakeCompleted(let proto) = e, !done {
            done = true
            promise.succeed(proto)
            context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !done { done = true; promise.fail(error) }
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !done { done = true; promise.fail(ChannelError.eof) }
        context.fireChannelInactive()
    }
}

/// Watches the client-facing handshake: success proves the CA is trusted; failure
/// after that point suggests the client pins certificates for this host.
final class ClientHandshakeWatcher: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = NIOAny
    private let onResult: (Result<Void, Error>) -> Void
    private var done = false

    init(onResult: @escaping (Result<Void, Error>) -> Void) { self.onResult = onResult }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let e = event as? TLSUserEvent, case .handshakeCompleted = e, !done {
            done = true
            onResult(.success(()))
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !done { done = true; onResult(.failure(error)) }
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !done { done = true; onResult(.failure(ChannelError.eof)) }
        context.fireChannelInactive()
    }
}
