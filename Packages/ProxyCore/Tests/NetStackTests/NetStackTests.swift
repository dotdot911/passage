import Foundation
import Testing
import TestSupport
@testable import NetStack

private final class Recorder: NetStackDelegate, @unchecked Sendable {
    var emitted: [Data] = []
    var accepted: [TCPConnection] = []
    var received = Data()
    func netStack(_ stack: NetStack, emit packet: Data) { emitted.append(packet) }
    func netStack(_ stack: NetStack, didAccept connection: TCPConnection) {
        accepted.append(connection)
        connection.onData = { [unowned self, unowned connection] data in
            self.received.append(data)
            connection.consumed(data.count)
        }
    }
}

@Suite(.serialized) struct NetStackTests {
    @Test func acceptsConnectionToAnyDestinationAndRelaysData() {
        let stack = NetStack.shared
        let rec = Recorder()
        stack.queue.sync {
            stack.delegate = rec
            stack.start()

            // Handshake: SYN -> SYN-ACK
            stack.input(PacketFixtures.tcp4(seq: 1000, flags: PacketFixtures.SYN))
            #expect(rec.emitted.count == 1)
            let synAck = PacketFixtures.parseTCP4(rec.emitted[0])
            #expect(synAck.flags & PacketFixtures.SYN != 0)
            #expect(synAck.flags & PacketFixtures.ACK != 0)
            #expect(synAck.srcPort == 443)
            #expect(synAck.ack == 1001)

            // ACK completes the handshake -> accept callback with the ORIGINAL destination.
            stack.input(PacketFixtures.tcp4(seq: 1001, ack: synAck.seq + 1, flags: PacketFixtures.ACK))
            #expect(rec.accepted.count == 1)
            let conn = rec.accepted[0]
            #expect(conn.destination == IPEndpoint(address: PacketFixtures.server, port: 443))
            #expect(conn.source == IPEndpoint(address: PacketFixtures.client, port: 50000))

            // Client -> stack data
            stack.input(PacketFixtures.tcp4(seq: 1001, ack: synAck.seq + 1,
                                             flags: PacketFixtures.ACK | PacketFixtures.PSH,
                                             payload: Array("hello".utf8)))
            #expect(rec.received == Data("hello".utf8))

            // Stack -> client data comes out with the server as source.
            rec.emitted.removeAll()
            conn.write(Data("world".utf8))
            let out = rec.emitted.map(PacketFixtures.parseTCP4).first { !$0.payload.isEmpty }
            #expect(out?.payload == Data("world".utf8))
            #expect(out?.srcPort == 443)
            #expect(out?.dstPort == 50000)
            conn.abort()
        }
    }

    @Test func abortReleasesCallbacks() {
        final class Token {}
        let stack = NetStack.shared
        let rec = Recorder()
        weak var weakToken: Token?
        stack.queue.sync {
            stack.delegate = rec
            stack.start()
            stack.input(PacketFixtures.tcp4(srcPort: 50200, seq: 1000, flags: PacketFixtures.SYN))
            let synAck = PacketFixtures.parseTCP4(rec.emitted.last!)
            stack.input(PacketFixtures.tcp4(srcPort: 50200, seq: 1001, ack: synAck.seq + 1, flags: PacketFixtures.ACK))
            let conn = rec.accepted.last!
            do {
                let token = Token()
                weakToken = token
                conn.onData = { _ in _ = token }
                conn.onWritable = { _ = token }
            }
            #expect(weakToken != nil)
            conn.abort()
            #expect(weakToken == nil)
        }
    }
}
