import Foundation
import ProxyModel
import Testing
@testable import Viewing

@Suite struct ProtobufDecoderTests {
    func decode(_ bytes: [UInt8]) throws -> [ProtobufField] { try ProtobufDecoder.decode(Data(bytes)) }

    func decodeError(_ bytes: [UInt8]) -> ProtobufDecodeError? {
        do { _ = try ProtobufDecoder.decode(Data(bytes)); return nil } catch { return error }
    }

    @Test func scalars() throws {
        #expect(try decode([0x08, 0x96, 0x01]) == [ProtobufField(number: 1, wireType: .varint, value: .varint(150))])
        let fixed = try decode([0x0D, 0x00, 0x00, 0x80, 0x3F, 0x11, 0, 0, 0, 0, 0, 0, 0xF0, 0x3F])
        #expect(fixed.map(\.value) == [.fixed32(0x3F80_0000), .fixed64(0x3FF0_0000_0000_0000)])
        #expect(try decode([0x08, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]).first?.value == .varint(.max))
        #expect(try decode([]) == [])
    }

    @Test func lengthDelimitedGuesses() throws {
        let fields = try decode([0x12, 0x07] + Array("testing".utf8) + [0x1A, 0x03, 0x08, 0x96, 0x01, 0x22, 0x02, 0xFF, 0x00, 0x2A, 0x00])
        #expect(fields.map(\.value) == [
            .string("testing"),
            .message([ProtobufField(number: 1, wireType: .varint, value: .varint(150))]),
            .bytes(Data([0xFF, 0x00])),
            .string(""),
        ])
        #expect(fields.map(\.number) == [2, 3, 4, 5])
        #expect(fields.allSatisfy { $0.wireType == .lengthDelimited })
    }

    @Test func nestedMessageMustUseEveryByte() throws {
        // 08 96 01 08 parses as a field and then a truncated varint: not a message, and not text either.
        let fields = try decode([0x0A, 0x04, 0x08, 0x96, 0x01, 0x08])
        #expect(fields.first?.value == .bytes(Data([0x08, 0x96, 0x01, 0x08])))
    }

    @Test func groups() throws {
        let fields = try decode([0x0B, 0x08, 0x01, 0x0C, 0x10, 0x02])
        #expect(fields == [
            ProtobufField(number: 1, wireType: .startGroup, value: .message([ProtobufField(number: 1, wireType: .varint, value: .varint(1))])),
            ProtobufField(number: 2, wireType: .varint, value: .varint(2)),
        ])
        #expect(decodeError([0x0B, 0x08, 0x01])?.message == "group 1 not closed")
        #expect(decodeError([0x0C])?.message == "unexpected end of group 1")
    }

    @Test func depthIsLimited() throws {
        // 40 nested messages: field 1 { field 1 { … { 1: 1 } } }.
        var bytes: [UInt8] = [0x08, 0x01]
        for _ in 0..<40 { bytes = [0x0A, UInt8(bytes.count)] + bytes }
        var value = try decode(bytes).first!.value
        var depth = 0
        while case .message(let inner) = value { depth += 1; value = inner[0].value }
        #expect(depth == ProtobufDecoder.maxDepth)
        guard case .bytes = value else { Issue.record("expected bytes past the depth limit"); return }
    }

    @Test func errors() {
        #expect(decodeError([0x08]) == ProtobufDecodeError(message: "truncated varint", offset: 1))
        #expect(decodeError([0x08, 0xFF]) == ProtobufDecodeError(message: "truncated varint", offset: 1))
        #expect(decodeError([0x08] + Array(repeating: 0xFF, count: 10) + [0x01])?.message == "varint longer than 10 bytes")
        #expect(decodeError([0x0E, 0x01])?.message == "invalid wire type 6")
        #expect(decodeError([0x12, 0x05, 0x61]) == ProtobufDecodeError(message: "length 5 runs past the end", offset: 1))
        #expect(decodeError([0x00, 0x01])?.message == "invalid field number 0")
        #expect(decodeError([0x0D, 0x01, 0x02])?.message == "truncated 32-bit value")
        #expect(decodeError([0x08])?.description == "truncated varint at byte 1")
    }

    @Test func display() {
        #expect(ProtobufDecoder.display(.varint(150)) == "150 (sint: 75)")
        #expect(ProtobufDecoder.display(.varint(0)) == "0")
        #expect(ProtobufDecoder.display(.varint(1)) == "1 (sint: -1)")
        #expect(ProtobufDecoder.display(.varint(.max)) == "18446744073709551615 (int: -1, sint: -9223372036854775808)")
        #expect(ProtobufDecoder.display(.fixed32(0x3F80_0000)) == "1065353216 (float: 1.0)")
        #expect(ProtobufDecoder.display(.fixed64(0x4004_0000_0000_0000)) == "4612811918334230528 (double: 2.5)")
        #expect(ProtobufDecoder.display(.string("a\"b\\\n\u{7}")) == #""a\"b\\\n\x07""#)
        #expect(ProtobufDecoder.display(.bytes(Data([0x01, 0x41, 0x22, 0xFF]))) == #""\x01A\"\xff""#)
    }

    @Test func text() throws {
        let fields = try decode([0x08, 0x96, 0x01, 0x1A, 0x08, 0x12, 0x02, 0x68, 0x69, 0x1A, 0x02, 0x08, 0x00, 0x22, 0x01, 0x80])
        #expect(ProtobufDecoder.text(fields) == """
        1: 150 (sint: 75)
        3 {
          2: "hi"
          3 {
            1: 0
          }
        }
        4: "\\x80"
        """)
    }
}

@Suite struct GRPCFramingTests {
    func frame(_ payload: [UInt8], flags: UInt8 = 0) -> [UInt8] {
        let n = payload.count
        return [flags, UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + payload
    }

    static let gzipped150 = [UInt8](Data(base64Encoded: "H4sIAAAAAAAC/+OYxggAoJVOoQMAAAA=")!)
    static let zlib150 = [UInt8](Data(base64Encoded: "eJzjmMYIAAFIAKA=")!)

    @Test func splitsFramesAndTrailers() {
        let body = frame([0x08, 0x96, 0x01]) + frame([]) + frame(Array("grpc-status: 0\r\ngrpc-message: ok\r\n".utf8), flags: 0x80)
        let split = GRPCFraming.split(Data(body), encoding: nil)
        #expect(split.error == nil)
        #expect(split.frames.map(\.kind) == [.message(Data([0x08, 0x96, 0x01])), .message(Data()), .trailers("grpc-status: 0\r\ngrpc-message: ok\r\n")])
    }

    @Test func decompressesFrames() {
        let split = GRPCFraming.split(Data(frame(Self.gzipped150, flags: 1) + frame(Self.zlib150, flags: 1)), encoding: "gzip")
        #expect(split.frames.first == GRPCFrame(kind: .message(Data([0x08, 0x96, 0x01])), compressed: true))
        // A frame that does not match the declared encoding keeps its raw payload and says why.
        #expect(split.frames.last?.error?.hasPrefix("gzip") == true)
        #expect(GRPCFraming.split(Data(frame(Self.zlib150, flags: 1)), encoding: "deflate").frames.first?.kind == .message(Data([0x08, 0x96, 0x01])))
        #expect(GRPCFraming.split(Data(frame([1], flags: 1)), encoding: nil).frames.first?.error == "compressed frame without grpc-encoding")
    }

    @Test func keepsFramesBeforeTruncation() {
        let whole = frame([0x08, 0x01])
        let header = GRPCFraming.split(Data(whole + [0, 0]), encoding: nil)
        #expect(header.frames.count == 1 && header.error == "truncated frame header at byte 7")
        let payload = GRPCFraming.split(Data(whole + frame([1, 2, 3]).dropLast()), encoding: nil)
        #expect(payload.frames.count == 1 && payload.error == "frame at byte 7 needs 3 bytes, 2 left")
    }

    @Test func grpcWebTextWithConcatenatedChunks() {
        let a = Data(frame([0x08, 0x96, 0x01])).base64EncodedString()
        let b = Data(frame(Array("grpc-status: 0".utf8), flags: 0x80)).base64EncodedString()
        #expect(a.hasSuffix("="))
        let split = GRPCFraming.split(Data((a + "\r\n" + b).utf8), encoding: nil, base64Text: true)
        #expect(split.error == nil)
        #expect(split.frames.map(\.kind) == [.message(Data([0x08, 0x96, 0x01])), .trailers("grpc-status: 0")])
        #expect(GRPCFraming.split(Data("!!!!".utf8), encoding: nil, base64Text: true).error == "invalid base64")
    }
}

@Suite struct ProtobufPreviewTests {
    func headers(_ type: String, _ extra: [HeaderField] = []) -> [HeaderField] { [HeaderField(name: "Content-Type", value: type)] + extra }

    @Test func sniffsProtobufTypes() {
        #expect(ContentSniffer.sniff(contentType: "application/x-protobuf", data: Data()) == .protobuf(framing: .none))
        #expect(ContentSniffer.sniff(contentType: "application/vnd.google.protobuf; proto=a.B", data: Data()) == .protobuf(framing: .none))
        #expect(ContentSniffer.sniff(contentType: "application/grpc", data: Data()) == .protobuf(framing: .grpc))
        #expect(ContentSniffer.sniff(contentType: "application/grpc-web+proto", data: Data()) == .protobuf(framing: .grpc))
        #expect(ContentSniffer.sniff(contentType: "application/grpc-web-text", data: Data()) == .protobuf(framing: .grpcWebText))
        #expect(ContentSniffer.sniff(contentType: "application/octet-stream", data: Data([0x08, 0x96, 0x01, 0xFF])) == .binary)
    }

    @Test func plainProtobufBody() {
        let p = BodyPreview(raw: Data([0x08, 0x96, 0x01]), storedSize: 3, headers: headers("application/protobuf"))
        #expect(p.protobuf == [ProtobufMessage(fields: [ProtobufField(number: 1, wireType: .varint, value: .varint(150))])])
        #expect(p.fullText() == "1: 150 (sint: 75)")
        let broken = BodyPreview(raw: Data([0x08]), storedSize: 1, headers: headers("application/protobuf"))
        #expect(broken.fullText() == "# error: truncated varint at byte 1")
    }

    @Test func grpcBodyUsesGrpcEncoding() {
        let body = GRPCFramingTests().frame(GRPCFramingTests.gzipped150, flags: 1)
            + GRPCFramingTests().frame([0x10, 0x01]) + GRPCFramingTests().frame(Array("grpc-status: 0\r\n".utf8), flags: 0x80)
        let p = BodyPreview(raw: Data(body), storedSize: body.count,
                            headers: headers("application/grpc-web+proto", [HeaderField(name: "grpc-encoding", value: "gzip")]))
        #expect(p.protobuf.count == 3)
        #expect(p.fullText() == "# message 1\n1: 150 (sint: 75)\n\n# message 2\n2: 1 (sint: -1)\n\n# trailers\ngrpc-status: 0")
        let cut = BodyPreview(raw: Data(body.prefix(3)), storedSize: 3, headers: headers("application/grpc"))
        #expect(cut.fullText() == "# error: truncated frame header at byte 0")
    }

    @Test func decodeAsProtobufButton() {
        #expect(BodyPreview.decodeProtobuf(Data([0x08, 0x01])).first?.fields?.count == 1)
        #expect(BodyPreview.decodeProtobuf(Data([0x0F])).first?.error == "invalid wire type 7 at byte 0")
    }
}
