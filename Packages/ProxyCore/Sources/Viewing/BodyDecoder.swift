import Compression
import CZstd
import Foundation

/// A body after undoing its `Content-Encoding`.
public struct DecodedBody: Sendable, Equatable {
    /// The decoded bytes, or the raw bytes when decoding failed.
    public var data: Data
    /// Encodings that were undone, in the order they were undone.
    public var appliedEncodings: [String]
    /// Size of the bytes that were decoded (as read from disk).
    public var rawSize: Int
    /// True when the input was cut short or the output hit `BodyDecoder.maxOutputBytes`.
    public var truncated: Bool
    /// Why decoding stopped early, if it did.
    public var error: String?
}

public enum BodyDecoder {
    /// Decoded output is capped here, which also defeats decompression bombs.
    public static let maxOutputBytes = 10 * 1024 * 1024

    /// Undoes every encoding in `contentEncoding` (e.g. "gzip, br": br is undone first).
    /// - Parameters:
    ///   - inputTruncated: the raw bytes are only a prefix of the stored body.
    ///   - maxOutput: output cap, `maxOutputBytes` unless a test needs a smaller one.
    public static func decode(_ raw: Data, contentEncoding: String?, inputTruncated: Bool = false,
                              maxOutput: Int = maxOutputBytes) -> DecodedBody {
        let encodings = (contentEncoding ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && $0 != "identity" }
        var result = DecodedBody(data: raw, appliedEncodings: [], rawSize: raw.count, truncated: inputTruncated)
        for encoding in encodings.reversed() {
            let step: Step
            switch encoding {
            case "gzip", "x-gzip": step = gunzip(result.data, maxOutput: maxOutput)
            case "deflate": step = inflateDeflate(result.data, maxOutput: maxOutput)
            case "br": step = stream(result.data, algorithm: COMPRESSION_BROTLI, maxOutput: maxOutput)
            case "zstd": step = unzstd(result.data, maxOutput: maxOutput)
            default:
                result.error = "Unsupported encoding \"\(encoding)\""
                return result
            }
            // A cut-off input always ends mid-stream: that is expected, not a failure.
            let error = step.error ?? (step.incomplete && !inputTruncated ? "truncated stream" : nil)
            if let error, step.data.isEmpty {
                result.error = "\(encoding): \(error)"
                return result
            }
            result.data = step.data
            result.appliedEncodings.append(encoding)
            result.truncated = result.truncated || step.capped
            if let error { result.error = "\(encoding): \(error)" }
        }
        return result
    }

    struct Step {
        var data: Data
        var capped = false
        /// The input ended before the end of the compressed stream.
        var incomplete = false
        /// The input is not valid for this encoding.
        var error: String?
    }

    // MARK: gzip / deflate

    static func gunzip(_ data: Data, maxOutput: Int) -> Step {
        let b = [UInt8](data)
        guard b.count >= 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { return Step(data: Data(), error: "not gzip data") }
        let flags = b[3]
        var i = 10
        if flags & 0x04 != 0 { // FEXTRA
            guard i + 2 <= b.count else { return Step(data: Data(), error: "bad gzip header") }
            i += 2 + Int(b[i]) | Int(b[i + 1]) << 8
        }
        if flags & 0x08 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 } // FNAME
        if flags & 0x10 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 } // FCOMMENT
        if flags & 0x02 != 0 { i += 2 } // FHCRC
        guard i < b.count else { return Step(data: Data(), error: "bad gzip header") }
        return stream(Data(b[i...]), algorithm: COMPRESSION_ZLIB, maxOutput: maxOutput)
    }

    /// HTTP "deflate" is meant to be zlib-wrapped, but some servers send raw deflate.
    static func inflateDeflate(_ data: Data, maxOutput: Int) -> Step {
        let b = [UInt8](data.prefix(2))
        let zlibWrapped = b.count == 2 && b[0] & 0x0f == 8 && (UInt16(b[0]) << 8 | UInt16(b[1])) % 31 == 0
        return stream(zlibWrapped ? data.dropFirst(2) : data, algorithm: COMPRESSION_ZLIB, maxOutput: maxOutput)
    }

    // MARK: Compression framework (raw deflate, brotli)

    static func stream(_ input: Data, algorithm: compression_algorithm, maxOutput: Int) -> Step {
        guard !input.isEmpty else { return Step(data: Data()) }
        let dst = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { dst.deallocate() }
        guard compression_stream_init(dst, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK else {
            return Step(data: Data(), error: "decoder init failed")
        }
        defer { compression_stream_destroy(dst) }
        let chunk = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        var output = Data()
        return input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Step in
            dst.pointee.src_ptr = src.bindMemory(to: UInt8.self).baseAddress!
            dst.pointee.src_size = src.count
            while true {
                dst.pointee.dst_ptr = buffer
                dst.pointee.dst_size = chunk
                // No FINALIZE flag: a cut-off stream then stalls (OK, no progress) instead of failing.
                let status = compression_stream_process(dst, 0)
                output.append(buffer, count: chunk - dst.pointee.dst_size)
                if output.count >= maxOutput { return Step(data: output.prefix(maxOutput), capped: true) }
                switch status {
                case COMPRESSION_STATUS_END: return Step(data: output)
                case COMPRESSION_STATUS_OK:
                    // No progress with all input consumed means the stream was cut short.
                    if dst.pointee.src_size == 0 && dst.pointee.dst_size == chunk {
                        return Step(data: output, incomplete: true)
                    }
                default: return Step(data: output, error: "corrupt data")
                }
            }
        }
    }

    // MARK: zstd

    static func unzstd(_ input: Data, maxOutput: Int) -> Step {
        guard let ctx = ZSTD_createDStream() else { return Step(data: Data(), error: "decoder init failed") }
        defer { ZSTD_freeDStream(ctx) }
        ZSTD_initDStream(ctx)
        let chunk = ZSTD_DStreamOutSize()
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 1)
        defer { buffer.deallocate() }
        var output = Data()
        return input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Step in
            var inBuf = ZSTD_inBuffer(src: src.baseAddress, size: src.count, pos: 0)
            var last = 0
            while true {
                var outBuf = ZSTD_outBuffer(dst: buffer, size: chunk, pos: 0)
                last = ZSTD_decompressStream(ctx, &outBuf, &inBuf)
                if ZSTD_isError(last) != 0 {
                    return Step(data: output, error: String(cString: ZSTD_getErrorName(last)))
                }
                output.append(buffer.assumingMemoryBound(to: UInt8.self), count: outBuf.pos)
                if output.count >= maxOutput { return Step(data: output.prefix(maxOutput), capped: true) }
                // Input used up and the decoder had room left: nothing more will come out.
                if inBuf.pos == inBuf.size && outBuf.pos < outBuf.size { break }
            }
            return Step(data: output, incomplete: last != 0)
        }
    }
}
