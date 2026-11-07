import Bridge
import Foundation
import NIOCore
import NIOPosix
import NetStack
import Testing
import TestSupport

/// Echo handler for the engine side of the bridge.
private final class Echo: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.writeAndFlush(data, promise: nil)
    }
}

private final class Harness: NetStackDelegate, @unchecked Sendable {
    let group: EventLoopGroup
    var emitted: [Data] = []
    var bridged: EventLoopFuture<Channel>?
    init(group: EventLoopGroup) { self.group = group }
    func netStack(_ stack: NetStack, emit packet: Data) { emitted.append(packet) }
    func netStack(_ stack: NetStack, didAccept connection: TCPConnection) {
        bridged = SocketBridge.attach(connection, stack: stack, group: group) { ch in
            ch.eventLoop.makeCompletedFuture { try ch.pipeline.syncOperations.addHandler(Echo()) }
        }
    }
}

@Suite struct SocketBridgeTests {
    @Test func bytesRoundTripThroughEngineChannel() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let stack = NetStack.shared
        let h = Harness(group: group)
        let port: UInt16 = 50100
        let synAck: (srcPort: UInt16, dstPort: UInt16, seq: UInt32, ack: UInt32, flags: UInt8, payload: Data) = stack.queue.sync {
            stack.delegate = h
            stack.start()
            stack.input(PacketFixtures.tcp4(srcPort: port, dstPort: 80, seq: 1, flags: PacketFixtures.SYN))
            return PacketFixtures.parseTCP4(h.emitted.last!)
        }
        let bridged: EventLoopFuture<Channel>? = stack.queue.sync {
            stack.input(PacketFixtures.tcp4(srcPort: port, dstPort: 80, seq: 2, ack: synAck.seq + 1, flags: PacketFixtures.ACK))
            return h.bridged
        }
        _ = try await bridged!.get()
        stack.queue.sync {
            h.emitted.removeAll()
            stack.input(PacketFixtures.tcp4(srcPort: port, dstPort: 80, seq: 2, ack: synAck.seq + 1,
                                             flags: PacketFixtures.ACK | PacketFixtures.PSH, payload: Array("ping".utf8)))
        }
        // Echo travels: lwIP -> pump -> socketpair -> Echo -> socketpair -> pump -> lwIP -> emitted packet.
        var echoed = Data()
        for _ in 0..<100 where echoed.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
            echoed = stack.queue.sync {
                h.emitted.map(PacketFixtures.parseTCP4).map(\.payload).reduce(Data(), +)
            }
        }
        #expect(echoed == Data("ping".utf8))
    }

    @Test func notifyingAbortClosesEngineChannel() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let stack = NetStack.shared
        let h = Harness(group: group)
        let port: UInt16 = 50110
        let synAck: (srcPort: UInt16, dstPort: UInt16, seq: UInt32, ack: UInt32, flags: UInt8, payload: Data) = stack.queue.sync {
            stack.delegate = h
            stack.start()
            stack.input(PacketFixtures.tcp4(srcPort: port, dstPort: 80, seq: 1, flags: PacketFixtures.SYN))
            return PacketFixtures.parseTCP4(h.emitted.last!)
        }
        let bridged: EventLoopFuture<Channel>? = stack.queue.sync {
            stack.input(PacketFixtures.tcp4(srcPort: port, dstPort: 80, seq: 2, ack: synAck.seq + 1, flags: PacketFixtures.ACK))
            return h.bridged
        }
        let engine = try await bridged!.get()
        #expect(engine.isActive)

        // What TunnelEngine.dropAllConnections does on a network change.
        stack.queue.sync {
            for conn in Array(stack.connections.values) where conn.source.port == port { conn.abort(notify: true) }
        }

        var closed = false
        for _ in 0..<200 where !closed {
            try await Task.sleep(for: .milliseconds(10))
            closed = !engine.isActive
        }
        #expect(closed)
    }
}
