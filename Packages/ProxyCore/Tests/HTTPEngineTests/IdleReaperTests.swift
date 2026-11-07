import Foundation
@testable import HTTPEngine
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import Testing

@Suite struct IdleReaperTests {
    let now = NIOLockedValueBox<TimeInterval>(1000)
    var reaper: IdleReaper { IdleReaper(clock: { [now] in now.withLockedValue { $0 } }) }

    func connected() throws -> EmbeddedChannel {
        let channel = EmbeddedChannel()
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()
        return channel
    }

    func advance(_ seconds: TimeInterval) { now.withLockedValue { $0 += seconds } }

    @Test func idleConnectionsCloseAfterTheLimit() throws {
        let reaper = self.reaper
        let channel = try connected()
        try reaper.track(channel)
        advance(IdleReaper.idleLimit - 1)
        reaper.sweep()
        #expect(channel.isActive)
        advance(1)
        reaper.sweep()
        #expect(!channel.isActive)
        channel.embeddedEventLoop.run()
        #expect(reaper.count == 0)
    }

    @Test func trafficAndRequestsInFlightKeepAConnectionOpen() throws {
        let reaper = self.reaper
        let channel = try connected()
        try reaper.track(channel)
        advance(IdleReaper.idleLimit - 1)
        try channel.writeInbound(ByteBuffer(string: "data"))
        advance(IdleReaper.idleLimit - 1)
        reaper.sweep()
        #expect(channel.isActive)

        reaper.begin(channel)
        advance(IdleReaper.idleLimit * 10)
        reaper.sweep()
        #expect(channel.isActive)

        reaper.end(channel)
        advance(IdleReaper.idleLimit)
        reaper.sweep()
        #expect(!channel.isActive)
    }

    @Test func memoryPressureShortensTheLimit() throws {
        let reaper = self.reaper
        let channel = try connected()
        try reaper.track(channel)
        advance(IdleReaper.pressureIdleLimit)
        reaper.sweep()
        #expect(channel.isActive)
        reaper.setPressure(true)
        #expect(!channel.isActive)
    }
}
