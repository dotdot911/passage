import Foundation
import ProxyModel
import zlib

/// Why a WebSocket byte stream could not be parsed, with the messages completed before the problem.
public struct WebSocketParseError: Error, CustomStringConvertible {
    public var reason: String
    public var messages: [WebSocketFrameParser.ParsedMessage]
    public var description: String { reason }
}

/// Splits one direction of a WebSocket connection (RFC 6455) into messages and inflates permessage-deflate
/// (RFC 7692). Bytes may arrive in any chunking. The zlib context is shared by copies, so keep one parser per direction.
public struct WebSocketFrameParser {
    public struct ParsedMessage: Sendable, Equatable {
        public var opcode: WebSocketOpcode
        /// Unmasked and inflated, cut at `maxPayload`.
        public var payload: Data
        /// The full message length, inflated for compressed messages. Always measured: a compressed message is
        /// inflated to the end (to keep the shared context right) even when only `maxPayload` bytes are kept.
        public var length: Int
        public var truncated: Bool

        public init(opcode: WebSocketOpcode, payload: Data, length: Int, truncated: Bool) {
            self.opcode = opcode
            self.payload = payload
            self.length = length
            self.truncated = truncated
        }
    }

    /// A compressed message is buffered whole before inflating; a larger one stops the parser.
    public static let maxCompressedBytes = 16 * 1024 * 1024
    /// A message that inflates beyond this stops the parser, which defeats decompression bombs.
    public static let maxInflatedBytes = 64 * 1024 * 1024

    public let maxPayload: Int
    /// Why parsing stopped; once set, `feed` returns nothing.
    public private(set) var failure: String?

    private let perMessageDeflate: Bool
    private let noContextTakeover: Bool
    private var inflater: Inflater?

    private var headerBytes: [UInt8] = []
    /// The frame whose payload is being read, if any.
    private var frame: FrameHeader?
    private var remaining = 0
    private var maskOffset = 0
    private var control: [UInt8] = []
    /// The data message being assembled from one or more frames.
    private var message: (opcode: WebSocketOpcode, compressed: Bool)?
    private var kept: [UInt8] = []
    private var length = 0
    private var compressed: [UInt8] = []

    /// - Parameters:
    ///   - perMessageDeflate: the 101 response accepted `permessage-deflate`.
    ///   - noContextTakeover: the sender of this direction resets its compression context after every message.
    ///   - maxPayload: payload bytes kept per message.
    public init(perMessageDeflate: Bool, noContextTakeover: Bool, maxPayload: Int = 256 * 1024) {
        self.perMessageDeflate = perMessageDeflate
        self.noContextTakeover = noContextTakeover
        self.maxPayload = maxPayload
    }

    /// Parses more bytes and returns the messages they complete. Throws once on a protocol or inflate error.
    public mutating func feed(_ bytes: some Collection<UInt8>) throws(WebSocketParseError) -> [ParsedMessage] {
        guard failure == nil else { return [] }
        var out: [ParsedMessage] = []
        do {
            try consume(Array(bytes), into: &out)
        } catch {
            failure = error.reason
            throw WebSocketParseError(reason: error.reason, messages: out)
        }
        return out
    }

    struct Failure: Error {
        var reason: String
        init(_ reason: String) { self.reason = reason }
    }

    private struct FrameHeader {
        var fin: Bool
        var rsv1: Bool
        var opcode: UInt8
        var mask: [UInt8]?
        var length: Int
        var isControl: Bool { opcode >= 8 }
    }

    private mutating func consume(_ input: [UInt8], into out: inout [ParsedMessage]) throws(Failure) {
        var i = 0
        while i < input.count {
            guard frame != nil else {
                headerBytes.append(input[i])
                i += 1
                guard let header = try parsedHeader() else { continue }
                headerBytes.removeAll(keepingCapacity: true)
                try begin(header)
                if header.length == 0 { try endFrame(into: &out) }
                continue
            }
            let n = min(remaining, input.count - i)
            var chunk = Array(input[i..<i + n])
            if let mask = frame?.mask {
                for k in chunk.indices { chunk[k] ^= mask[(maskOffset + k) & 3] }
                maskOffset = (maskOffset + n) & 3
            }
            i += n
            remaining -= n
            try deliver(chunk)
            if remaining == 0 { try endFrame(into: &out) }
        }
    }

    /// The header once all of its bytes (2 to 14) are in `headerBytes`.
    private func parsedHeader() throws(Failure) -> FrameHeader? {
        let b = headerBytes
        guard b.count >= 2 else { return nil }
        guard b[0] & 0x30 == 0 else { throw Failure("reserved bits set") }
        let len7 = Int(b[1] & 0x7F)
        let extended = len7 == 126 ? 2 : len7 == 127 ? 8 : 0
        let masked = b[1] & 0x80 != 0
        guard b.count == 2 + extended + (masked ? 4 : 0) else { return nil }
        var length = len7
        if extended > 0 {
            var value: UInt64 = 0
            for byte in b[2..<2 + extended] { value = value << 8 | UInt64(byte) }
            guard value >> 63 == 0 else { throw Failure("frame length has the most significant bit set") }
            length = Int(value)
        }
        return FrameHeader(fin: b[0] & 0x80 != 0, rsv1: b[0] & 0x40 != 0, opcode: b[0] & 0x0F,
                           mask: masked ? Array(b[(2 + extended)...]) : nil, length: length)
    }

    private mutating func begin(_ header: FrameHeader) throws(Failure) {
        let opcode: WebSocketOpcode?
        switch header.opcode {
        case 0: opcode = nil
        case 1: opcode = .text
        case 2: opcode = .binary
        case 8: opcode = .close
        case 9: opcode = .ping
        case 10: opcode = .pong
        default: throw Failure(String(format: "reserved opcode 0x%X", header.opcode))
        }
        if header.isControl {
            guard header.fin else { throw Failure("fragmented control frame") }
            guard header.length <= 125 else { throw Failure("control frame of \(header.length) bytes") }
            guard !header.rsv1 else { throw Failure("compressed control frame") }
            control = []
        } else if let opcode {
            guard message == nil else { throw Failure("new message before the previous one ended") }
            guard !header.rsv1 || perMessageDeflate else { throw Failure("RSV1 set without permessage-deflate") }
            message = (opcode, header.rsv1)
            kept = []
            length = 0
            compressed = []
        } else {
            guard message != nil else { throw Failure("continuation frame without a message") }
            guard !header.rsv1 else { throw Failure("RSV1 set on a continuation frame") }
        }
        frame = header
        remaining = header.length
        maskOffset = 0
    }

    private mutating func deliver(_ chunk: [UInt8]) throws(Failure) {
        if frame?.isControl == true {
            control += chunk
        } else if message?.compressed == true {
            guard compressed.count + chunk.count <= Self.maxCompressedBytes else {
                throw Failure("compressed message over \(Self.maxCompressedBytes / 1024 / 1024) MB")
            }
            compressed += chunk
        } else {
            length += chunk.count
            if kept.count < maxPayload { kept += chunk.prefix(maxPayload - kept.count) }
        }
    }

    private mutating func endFrame(into out: inout [ParsedMessage]) throws(Failure) {
        guard let header = frame else { return }
        frame = nil
        if header.isControl {
            let opcode: WebSocketOpcode = header.opcode == 8 ? .close : header.opcode == 9 ? .ping : .pong
            out.append(ParsedMessage(opcode: opcode, payload: Data(control.prefix(maxPayload)), length: control.count,
                                     truncated: control.count > maxPayload))
            control = []
            return
        }
        guard header.fin, let current = message else { return }
        if current.compressed {
            if inflater == nil { inflater = try Inflater() }
            compressed += [0x00, 0x00, 0xFF, 0xFF]
            let result = try inflater!.run(compressed, keep: maxPayload, limit: Self.maxInflatedBytes)
            kept = result.kept
            length = result.total
            if noContextTakeover { inflater!.reset() }
        }
        out.append(ParsedMessage(opcode: current.opcode, payload: Data(kept), length: length, truncated: length > kept.count))
        message = nil
        kept = []
        compressed = []
        length = 0
    }
}

/// A raw-deflate zlib stream kept alive across messages. The `z_stream` is heap-allocated because zlib keeps a
/// pointer back to it.
private final class Inflater {
    private let stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)

    init() throws(WebSocketFrameParser.Failure) {
        stream.initialize(to: z_stream())
        // Negative window bits: raw deflate without a zlib header, as permessage-deflate sends it.
        guard inflateInit2_(stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            stream.deinitialize(count: 1)
            stream.deallocate()
            throw .init("zlib init failed")
        }
    }

    deinit {
        inflateEnd(stream)
        stream.deinitialize(count: 1)
        stream.deallocate()
    }

    func reset() { inflateReset(stream) }

    /// Inflates all of `input`, keeping the first `keep` output bytes and counting the rest.
    func run(_ input: [UInt8], keep: Int, limit: Int) throws(WebSocketFrameParser.Failure) -> (kept: [UInt8], total: Int) {
        let src = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: input.count)
        _ = src.initialize(from: input)
        defer { src.deallocate() }
        let chunk = 32 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { dst.deallocate() }
        stream.pointee.next_in = src.baseAddress
        stream.pointee.avail_in = UInt32(src.count)
        var kept: [UInt8] = []
        var total = 0
        while true {
            stream.pointee.next_out = dst
            stream.pointee.avail_out = UInt32(chunk)
            let status = inflate(stream, Z_SYNC_FLUSH)
            let produced = chunk - Int(stream.pointee.avail_out)
            total += produced
            if kept.count < keep { kept += UnsafeBufferPointer(start: dst, count: min(produced, keep - kept.count)) }
            guard total <= limit else {
                inflateReset(stream)
                throw .init("message inflates to over \(limit / 1024 / 1024) MB")
            }
            switch status {
            case Z_OK:
                if stream.pointee.avail_in == 0 && stream.pointee.avail_out > 0 { return (kept, total) }
            case Z_STREAM_END:
                // The sender ended the deflate stream (BFINAL); what follows starts a new one.
                inflateReset(stream)
                if stream.pointee.avail_in == 0 { return (kept, total) }
            case Z_BUF_ERROR:
                return (kept, total)
            default:
                let detail = stream.pointee.msg.map { String(cString: $0) } ?? "error \(status)"
                throw .init("inflate failed: \(detail)")
            }
        }
    }
}
