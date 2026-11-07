import Foundation
import HTTPEngine
import ProxyModel
import Testing
import zlib

@Suite struct WebSocketFrameParserTests {
    typealias Message = WebSocketFrameParser.ParsedMessage

    func frame(_ opcode: UInt8, _ payload: [UInt8], fin: Bool = true, rsv1: Bool = false, mask: [UInt8]? = nil) -> [UInt8] {
        var out: [UInt8] = [(fin ? 0x80 : 0) | (rsv1 ? 0x40 : 0) | opcode]
        let maskBit: UInt8 = mask == nil ? 0 : 0x80
        switch payload.count {
        case ..<126: out.append(maskBit | UInt8(payload.count))
        case ..<65536: out += [maskBit | 126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        default: out += [maskBit | 127] + (0..<8).reversed().map { UInt8(truncatingIfNeeded: payload.count >> ($0 * 8)) }
        }
        guard let mask else { return out + payload }
        return out + mask + payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
    }

    func text(_ s: String) -> Message { Message(opcode: .text, payload: Data(s.utf8), length: s.utf8.count, truncated: false) }

    func parse(_ bytes: [UInt8], deflate: Bool = false, noContext: Bool = false, max: Int = 256 * 1024) throws -> [Message] {
        var parser = WebSocketFrameParser(perMessageDeflate: deflate, noContextTakeover: noContext, maxPayload: max)
        return try parser.feed(bytes)
    }

    func failure(_ bytes: [UInt8], deflate: Bool = false) -> WebSocketParseError? {
        var parser = WebSocketFrameParser(perMessageDeflate: deflate, noContextTakeover: false)
        do { _ = try parser.feed(bytes); return nil } catch { return error }
    }

    @Test func singleFramesWithEveryLengthEncoding() throws {
        #expect(try parse(frame(1, Array("hi".utf8))) == [text("hi")])
        let medium = [UInt8](repeating: 7, count: 300)
        let large = [UInt8](repeating: 9, count: 70_000)
        let messages = try parse(frame(2, medium) + frame(2, large, mask: [1, 2, 3, 4]) + frame(2, []))
        #expect(messages.map(\.payload) == [Data(medium), Data(large), Data()])
        #expect(messages.map(\.opcode) == [.binary, .binary, .binary])
    }

    @Test func masked() throws {
        #expect(try parse(frame(1, Array("Hello".utf8), mask: [0x37, 0xFA, 0x21, 0x3D])) == [text("Hello")])
        // RFC 6455 section 5.7 example.
        #expect(try parse([0x81, 0x85, 0x37, 0xFA, 0x21, 0x3D, 0x7F, 0x9F, 0x4D, 0x51, 0x58]) == [text("Hello")])
    }

    @Test func anyChunking() throws {
        let bytes = frame(1, Array("first".utf8), mask: [9, 8, 7, 6]) + frame(9, [1, 2]) + frame(2, [UInt8](repeating: 1, count: 1000), mask: [1, 1, 1, 1])
        let whole = try parse(bytes)
        var parser = WebSocketFrameParser(perMessageDeflate: false, noContextTakeover: false)
        var oneByOne: [Message] = []
        for b in bytes { oneByOne += try parser.feed([b]) }
        #expect(oneByOne == whole)
        #expect(whole.map(\.opcode) == [.text, .ping, .binary])
    }

    @Test func fragmentsWithInterleavedControlFrames() throws {
        let bytes = frame(1, Array("Hel".utf8), fin: false) + frame(9, Array("p".utf8)) + frame(0, Array("lo, ".utf8), fin: false, mask: [5, 6, 7, 8])
            + frame(10, []) + frame(0, Array("world".utf8)) + frame(8, [0x03, 0xE8] + Array("bye".utf8))
        let messages = try parse(bytes)
        #expect(messages.map(\.opcode) == [.ping, .pong, .text, .close])
        #expect(messages[2] == text("Hello, world"))
        #expect(messages[3].payload == Data([0x03, 0xE8] + Array("bye".utf8)))
    }

    @Test func payloadIsCutButLengthCounted() throws {
        let messages = try parse(frame(2, [UInt8](repeating: 1, count: 60), fin: false) + frame(0, [UInt8](repeating: 2, count: 40)), max: 50)
        #expect(messages == [Message(opcode: .binary, payload: Data(repeating: 1, count: 50), length: 100, truncated: true)])
        #expect(try parse(frame(9, [UInt8](repeating: 3, count: 20)), max: 8).first?.truncated == true)
    }

    // MARK: permessage-deflate

    /// A raw-deflate stream like a permessage-deflate sender's: each message ends with a sync flush, minus 00 00 FF FF.
    final class Deflater {
        let stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
        init() {
            stream.initialize(to: z_stream())
            precondition(deflateInit2_(stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY,
                                       ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
        }
        deinit { deflateEnd(stream); stream.deallocate() }
        func reset() { deflateReset(stream) }

        func compress(_ input: [UInt8]) -> [UInt8] {
            var src = input
            var out: [UInt8] = []
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            src.withUnsafeMutableBufferPointer { s in
                stream.pointee.next_in = s.baseAddress
                stream.pointee.avail_in = UInt32(s.count)
                repeat {
                    buffer.withUnsafeMutableBufferPointer { b in
                        stream.pointee.next_out = b.baseAddress
                        stream.pointee.avail_out = UInt32(b.count)
                        _ = deflate(stream, Z_SYNC_FLUSH)
                        out += b.prefix(b.count - Int(stream.pointee.avail_out))
                    }
                } while stream.pointee.avail_out == 0
            }
            precondition(out.suffix(4) == [0, 0, 0xFF, 0xFF])
            return Array(out.dropLast(4))
        }
    }

    @Test func rfc7692Examples() throws {
        // RFC 7692 section 7.2.3: "Hello" compressed, then again with the context taken over.
        let first: [UInt8] = [0xC1, 0x07, 0xF2, 0x48, 0xCD, 0xC9, 0xC9, 0x07, 0x00]
        let second: [UInt8] = [0xC1, 0x05, 0xF2, 0x00, 0x11, 0x00, 0x00]
        #expect(try parse(first + second, deflate: true) == [text("Hello"), text("Hello")])
        // The same "Hello" split over two frames, RSV1 on the first only.
        #expect(try parse([0x41, 0x03, 0xF2, 0x48, 0xCD, 0x80, 0x04, 0xC9, 0xC9, 0x07, 0x00], deflate: true) == [text("Hello")])
    }

    @Test func contextTakeoverAcrossMessages() throws {
        let deflater = Deflater()
        let message = Array(String(repeating: "the quick brown fox jumps over the lazy dog ", count: 20).utf8)
        let a = deflater.compress(message)
        let b = deflater.compress(message)
        #expect(b.count < a.count / 2)
        var parser = WebSocketFrameParser(perMessageDeflate: true, noContextTakeover: false)
        let messages = try parser.feed(frame(1, a, rsv1: true, mask: [1, 2, 3, 4]) + frame(1, Array("plain".utf8)) + frame(1, b, rsv1: true))
        #expect(messages.map(\.payload) == [Data(message), Data("plain".utf8), Data(message)])
        #expect(messages.map(\.length) == [message.count, 5, message.count])
    }

    @Test func noContextTakeoverResetsEachMessage() throws {
        let deflater = Deflater()
        let message = Array(String(repeating: "abcabcabc", count: 30).utf8)
        let a = deflater.compress(message)
        deflater.reset()
        let b = deflater.compress(message)
        #expect(a == b)
        let messages = try parse(frame(2, a, rsv1: true) + frame(2, b, rsv1: true), deflate: true, noContext: true)
        #expect(messages.map(\.payload) == [Data(message), Data(message)])
    }

    @Test func compressedMessageIsCutAfterInflating() throws {
        let message = [UInt8](repeating: 0x41, count: 100_000)
        let compressed = Deflater().compress(message)
        let parsed = try parse(frame(2, Array(compressed.prefix(10)), fin: false, rsv1: true) + frame(0, Array(compressed.dropFirst(10))),
                               deflate: true, max: 1000)
        #expect(parsed == [Message(opcode: .binary, payload: Data(repeating: 0x41, count: 1000), length: 100_000, truncated: true)])
    }

    @Test func corruptDeflateFails() {
        #expect(failure(frame(1, [0xFF, 0xFF, 0xFF], rsv1: true), deflate: true)?.reason.hasPrefix("inflate failed") == true)
    }

    // MARK: protocol errors

    @Test func protocolErrors() {
        #expect(failure(frame(3, []))?.reason == "reserved opcode 0x3")
        #expect(failure(frame(0xB, []))?.reason == "reserved opcode 0xB")
        #expect(failure([0xA1, 0x00])?.reason == "reserved bits set")
        #expect(failure(frame(9, [UInt8](repeating: 0, count: 126)))?.reason == "control frame of 126 bytes")
        #expect(failure(frame(9, [], fin: false))?.reason == "fragmented control frame")
        #expect(failure(frame(9, [], rsv1: true), deflate: true)?.reason == "compressed control frame")
        #expect(failure(frame(0, [1]))?.reason == "continuation frame without a message")
        #expect(failure(frame(1, [1], fin: false) + frame(1, [2]))?.reason == "new message before the previous one ended")
        #expect(failure(frame(1, [1], rsv1: true))?.reason == "RSV1 set without permessage-deflate")
        #expect(failure(frame(1, [1], fin: false) + frame(0, [2], rsv1: true), deflate: true)?.reason == "RSV1 set on a continuation frame")
        #expect(failure([0x82, 0x7F, 0x80, 0, 0, 0, 0, 0, 0, 0])?.reason == "frame length has the most significant bit set")
    }

    @Test func errorKeepsEarlierMessagesAndStopsTheParser() throws {
        var parser = WebSocketFrameParser(perMessageDeflate: false, noContextTakeover: false)
        do {
            _ = try parser.feed(frame(1, Array("ok".utf8)) + frame(3, []))
            Issue.record("expected an error")
        } catch {
            #expect(error.messages == [text("ok")])
        }
        #expect(parser.failure == "reserved opcode 0x3")
        #expect(try parser.feed(frame(1, Array("later".utf8))).isEmpty)
    }

    @Test func messageModelCodes() throws {
        let message = WebSocketMessage(flowID: UUID(), seq: 3, at: Date(timeIntervalSince1970: 0), direction: .received,
                                       opcode: .pong, length: 2, payload: Data([1, 2]), truncated: false)
        let json = String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
        #expect(json.contains(#""direction":"received""#) && json.contains(#""opcode":"pong""#))
        #expect(try JSONDecoder().decode(WebSocketMessage.self, from: Data(json.utf8)) == message)
    }
}
