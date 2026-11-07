@testable import HTTPEngine
import NIOCore
import NIOEmbedded
import ProxyModel
import Testing

@Suite struct ThrottleHandlerTests {
    @Test func shaperSpacesBytesByRateAfterLatency() {
        var s = ThrottleHandler.Shaper(kbps: 80, latencyMs: 100) // 10 000 bytes/s
        let t0 = NIODeadline.uptimeNanoseconds(0)
        #expect(s.release(10_000, now: t0) == t0 + .milliseconds(1100))
        #expect(s.release(10_000, now: t0) == t0 + .milliseconds(2100))
        var unlimited = ThrottleHandler.Shaper(kbps: nil, latencyMs: 0)
        #expect(unlimited.release(1_000_000, now: t0) == t0)
    }

    func written(_ channel: EmbeddedChannel) throws -> Int {
        var n = 0
        while let b = try channel.readOutbound(as: ByteBuffer.self) { n += b.readableBytes }
        return n
    }

    @Test func downloadOf20KBAt80kbpsTakesTwoSeconds() throws {
        let channel = EmbeddedChannel(handler: ThrottleHandler(profile: NetworkProfile(downloadKbps: 80, latencyMs: 0)))
        let promise = channel.eventLoop.makePromise(of: Void.self)
        channel.writeAndFlush(channel.allocator.buffer(repeating: 1, count: 20_000), promise: promise)
        #expect(try written(channel) == 0)
        channel.embeddedEventLoop.advanceTime(by: .milliseconds(1500))
        let early = try written(channel)
        #expect(early > 0 && early < 20_000)
        channel.embeddedEventLoop.advanceTime(by: .milliseconds(600))
        #expect(early + (try written(channel)) == 20_000)
        try promise.futureResult.wait()
    }

    @Test func uploadWaitsForLatencyAndCloseWaitsForQueuedBytes() throws {
        let channel = EmbeddedChannel(handler: ThrottleHandler(profile: NetworkProfile(latencyMs: 300)))
        try channel.writeInbound(channel.allocator.buffer(string: "hi"))
        #expect(try channel.readInbound(as: ByteBuffer.self) == nil)
        channel.embeddedEventLoop.advanceTime(by: .milliseconds(300))
        #expect(try channel.readInbound(as: ByteBuffer.self).map { String(buffer: $0) } == "hi")

        channel.writeAndFlush(channel.allocator.buffer(string: "bye"), promise: nil)
        var closedAt: Int?
        channel.close().whenComplete { _ in closedAt = (try? self.written(channel)) ?? -1 }
        #expect(closedAt == nil)
        channel.embeddedEventLoop.advanceTime(by: .milliseconds(300))
        #expect(closedAt == 3) // the queued bytes went out before the close
    }
}
