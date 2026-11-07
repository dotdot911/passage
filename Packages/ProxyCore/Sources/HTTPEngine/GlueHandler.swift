import NIOCore

/// Forwards bytes between two channels on the same event loop, with backpressure.
/// Adapted from the swift-nio `NIOConnectProxy` example.
final class GlueHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false
    /// Called with the byte count of each buffer this side receives.
    var onBytes: ((Int) -> Void)?
    /// Called with each buffer this side receives, before it is forwarded (the WebSocket tap).
    var onData: ((ByteBuffer) -> Void)?
    /// Called once when this side's channel goes inactive.
    var onClose: (() -> Void)?

    static func matchedPair() -> (GlueHandler, GlueHandler) {
        let a = GlueHandler(), b = GlueHandler()
        a.partner = b
        b.partner = a
        return (a, b)
    }

    func handlerAdded(context: ChannelHandlerContext) { self.context = context }
    func handlerRemoved(context: ChannelHandlerContext) { self.context = nil; partner = nil }

    private func partnerWrite(_ buffer: ByteBuffer) { context?.write(wrapOutboundOut(buffer), promise: nil) }
    private func partnerFlush() { context?.flush() }
    private func partnerWriteEOF() { context?.close(mode: .output, promise: nil) }
    private func partnerCloseFull() { context?.close(promise: nil) }
    private func partnerBecameWritable() {
        if pendingRead { pendingRead = false; context?.read() }
    }
    private var partnerWritable: Bool { context?.channel.isWritable ?? false }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        onBytes?(buffer.readableBytes)
        onData?(buffer)
        partner?.partnerWrite(buffer)
    }
    func channelReadComplete(context: ChannelHandlerContext) { partner?.partnerFlush() }
    func channelInactive(context: ChannelHandlerContext) {
        onClose?()
        onClose = nil
        partner?.partnerCloseFull()
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let e = event as? ChannelEvent, case .inputClosed = e { partner?.partnerWriteEOF() }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { partner?.partnerBecameWritable() }
    }
    func read(context: ChannelHandlerContext) {
        if let partner, partner.partnerWritable { context.read() } else { pendingRead = true }
    }
}
