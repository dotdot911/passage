import Foundation

/// One length-prefixed frame of a gRPC or gRPC-Web body.
public struct GRPCFrame: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// A message payload, decompressed when the frame was compressed.
        case message(Data)
        /// A gRPC-Web trailer frame (flag 0x80): `name: value` lines.
        case trailers(String)
    }

    public var kind: Kind
    /// The frame had the compressed flag (0x01).
    public var compressed: Bool
    /// Why a compressed payload could not be decompressed; `kind` then holds the raw payload.
    public var error: String?

    public init(kind: Kind, compressed: Bool = false, error: String? = nil) {
        self.kind = kind
        self.compressed = compressed
        self.error = error
    }
}

/// The frames of a body, plus why splitting stopped early, if it did.
public struct GRPCFrames: Sendable, Hashable {
    public var frames: [GRPCFrame]
    public var error: String?
}

public enum GRPCFraming {
    /// Splits a body into 5-byte-header frames (flag byte, 4-byte big-endian length).
    /// - Parameters:
    ///   - encoding: the `grpc-encoding` header, used for compressed frames (gzip, deflate, …).
    ///   - base64Text: the body is `application/grpc-web-text`, base64 (possibly several concatenated chunks).
    public static func split(_ body: Data, encoding: String?, base64Text: Bool = false) -> GRPCFrames {
        var data = body
        if base64Text {
            guard let decoded = decodeBase64Chunks(body) else { return GRPCFrames(frames: [], error: "invalid base64") }
            data = decoded
        }
        let b = [UInt8](data)
        var frames: [GRPCFrame] = []
        var i = 0
        while i < b.count {
            guard b.count - i >= 5 else { return GRPCFrames(frames: frames, error: "truncated frame header at byte \(i)") }
            let flags = b[i]
            let length = Int(b[i + 1]) << 24 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 8 | Int(b[i + 4])
            guard length <= b.count - i - 5 else {
                return GRPCFrames(frames: frames, error: "frame at byte \(i) needs \(length) bytes, \(b.count - i - 5) left")
            }
            var payload = Data(b[(i + 5)..<(i + 5 + length)])
            i += 5 + length
            let compressed = flags & 0x01 != 0
            var error: String?
            if compressed {
                let name = (encoding ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                if name.isEmpty || name == "identity" {
                    error = "compressed frame without grpc-encoding"
                } else {
                    let decoded = BodyDecoder.decode(payload, contentEncoding: name)
                    if let e = decoded.error { error = e } else { payload = decoded.data }
                }
            }
            let kind: GRPCFrame.Kind = flags & 0x80 != 0 ? .trailers(String(decoding: payload, as: UTF8.self)) : .message(payload)
            frames.append(GRPCFrame(kind: kind, compressed: compressed, error: error))
        }
        return GRPCFrames(frames: frames, error: nil)
    }

    /// gRPC-Web text sends each message as its own padded base64 string, so `=` can appear mid-body.
    static func decodeBase64Chunks(_ body: Data) -> Data? {
        var out = Data()
        var chunk = ""
        func flush() -> Bool {
            guard !chunk.isEmpty else { return true }
            let padded = chunk + String(repeating: "=", count: (4 - chunk.count % 4) % 4)
            guard let d = Data(base64Encoded: padded) else { return false }
            out.append(d)
            chunk = ""
            return true
        }
        var sawPadding = false
        for scalar in String(decoding: body, as: UTF8.self).unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            if scalar == "=" {
                chunk.unicodeScalars.append(scalar)
                sawPadding = true
                continue
            }
            if sawPadding {
                guard flush() else { return nil }
                sawPadding = false
            }
            chunk.unicodeScalars.append(scalar)
        }
        return flush() ? out : nil
    }
}
