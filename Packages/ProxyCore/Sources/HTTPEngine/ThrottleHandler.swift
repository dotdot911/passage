import Foundation
import NIOCore
import ProxyModel

/// Slows one client connection down: added latency each way and a bandwidth cap per direction.
/// Sits first in the client pipeline (next to the socket), so it shapes the bytes the app sees.
final class ThrottleHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    /// Bytes are released in slices this big so throughput is smooth.
    static let slice = 4096

    /// When the next byte may leave, given a rate; one per direction.
    struct Shaper {
        let bytesPerSecond: Double?
        let latency: TimeAmount
        var nextFree: NIODeadline = .distantPast

        init(kbps: Int?, latencyMs: Int) {
            bytesPerSecond = kbps.map { Double(max($0, 1)) * 125 }
            latency = .milliseconds(Int64(latencyMs))
        }

        /// The time `size` bytes arriving `now` have fully gone through.
        mutating func release(_ size: Int, now: NIODeadline) -> NIODeadline {
            let start = max(now + latency, nextFree)
            let duration = bytesPerSecond.map { TimeAmount.nanoseconds(Int64(Double(size) / $0 * 1_000_000_000)) } ?? .zero
            nextFree = start + duration
            return nextFree
        }
    }

    private var down: Shaper
    private var up: Shaper
    private var outboundPending = 0
    private var inboundPending = 0
    private var readPending = false
    private var closeRequest: (mode: CloseMode, promise: EventLoopPromise<Void>?)?

    init(profile: NetworkProfile) {
        down = Shaper(kbps: profile.downloadKbps, latencyMs: profile.latencyMs)
        up = Shaper(kbps: profile.uploadKbps, latencyMs: profile.latencyMs)
    }

    // MARK: Device → us (upload)

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        let now = context.eventLoop.now
        while let piece = buffer.readSlice(length: min(Self.slice, buffer.readableBytes)), piece.readableBytes > 0 {
            let at = up.release(piece.readableBytes, now: now)
            inboundPending += 1
            context.eventLoop.scheduleTask(deadline: at) { [self] in
                inboundPending -= 1
                context.fireChannelRead(wrapInboundOut(piece))
                context.fireChannelReadComplete()
                if inboundPending == 0 && readPending { readPending = false; context.read() }
            }
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {}

    /// Holds further reads while delayed bytes are queued, so the app feels the upload cap.
    func read(context: ChannelHandlerContext) {
        if inboundPending > 0 { readPending = true } else { context.read() }
    }

    // MARK: Us → device (download)

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        var buffer = unwrapOutboundIn(data)
        let now = context.eventLoop.now
        var slices: [ByteBuffer] = []
        while let piece = buffer.readSlice(length: min(Self.slice, buffer.readableBytes)), piece.readableBytes > 0 { slices.append(piece) }
        if slices.isEmpty { context.write(data, promise: promise); return }
        for (i, piece) in slices.enumerated() {
            let at = down.release(piece.readableBytes, now: now)
            let last = i == slices.count - 1
            outboundPending += 1
            context.eventLoop.scheduleTask(deadline: at) { [self] in
                outboundPending -= 1
                context.writeAndFlush(wrapOutboundOut(piece), promise: last ? promise : nil)
                if outboundPending == 0, let close = closeRequest {
                    closeRequest = nil
                    context.close(mode: close.mode, promise: close.promise)
                }
            }
        }
    }

    func flush(context: ChannelHandlerContext) {}

    /// A close waits for delayed bytes so nothing is lost.
    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        if outboundPending > 0 && mode != .input { closeRequest = (mode, promise) } else { context.close(mode: mode, promise: promise) }
    }
}
