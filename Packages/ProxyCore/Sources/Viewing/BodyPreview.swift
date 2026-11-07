import Foundation
import ProxyModel

/// A body ready to show: decoded, classified, parsed and summarised. Build it off the main thread;
/// views only read the results.
public struct BodyPreview: Sendable {
    /// At most this much of a stored body is read from disk.
    public static let maxRawBytes = 5 * 1024 * 1024
    /// Text shown inline is cut here; the full text is available through `fullText()`.
    public static let maxInlineTextBytes = 64 * 1024

    public var decoded: DecodedBody
    public var kind: BodyKind
    /// Size of the stored (still encoded) body file.
    public var storedSize: Int
    /// The parsed tree when `kind` is `.json` and the body parses.
    public var json: JSONNode?
    /// Fields when `kind` is `.form`.
    public var form: [(name: String, value: String)] = []
    /// Parts and their own previews when `kind` is `.multipart`.
    public var multipart: MultipartBody?
    public var partPreviews: [BodyPreview] = []
    /// Messages when `kind` is `.protobuf`: one for a plain body, one per frame (and trailer frame) for gRPC.
    public var protobuf: [ProtobufMessage] = []
    /// The first `maxInlineTextBytes` of the body as text (for text-like kinds and invalid JSON).
    public var inlineText = ""
    public var inlineTextTruncated = false

    /// - Parameters:
    ///   - raw: the first `maxRawBytes` (or fewer) of the stored body.
    ///   - storedSize: the full size of the stored body.
    ///   - headers: the message headers (Content-Encoding, Content-Type, grpc-encoding).
    public init(raw: Data, storedSize: Int, headers: [HeaderField]) {
        decoded = BodyDecoder.decode(raw, contentEncoding: headers.value(for: "Content-Encoding"),
                                     inputTruncated: storedSize > raw.count)
        kind = ContentSniffer.sniff(contentType: headers.value(for: "Content-Type"), data: decoded.data)
        self.storedSize = storedSize
        let data = decoded.data
        switch kind {
        case .json:
            json = try? JSONNode.parse(data)
            if json == nil { setInlineText(data) }
        case .form:
            form = FormParser.parse(String(decoding: data, as: UTF8.self))
        case .multipart(let boundary):
            let body = MultipartParser.parse(data, boundary: boundary)
            multipart = body
            partPreviews = body.parts.map { BodyPreview(raw: $0.data, storedSize: $0.data.count, headers: $0.headers) }
        case .html, .xml, .text:
            setInlineText(data)
        case .protobuf(let framing):
            protobuf = framing == .none ? Self.decodeProtobuf(data)
                : Self.grpcMessages(data, encoding: headers.value(for: "grpc-encoding"), base64Text: framing == .grpcWebText)
        case .image, .binary:
            break
        }
    }

    /// Decodes bytes as one protobuf message, for "Decode as Protobuf" on a binary body or WebSocket message.
    public static func decodeProtobuf(_ data: Data) -> [ProtobufMessage] {
        do throws(ProtobufDecodeError) {
            return [ProtobufMessage(fields: try ProtobufDecoder.decode(data))]
        } catch {
            return [ProtobufMessage(error: error.description)]
        }
    }

    static func grpcMessages(_ data: Data, encoding: String?, base64Text: Bool) -> [ProtobufMessage] {
        let split = GRPCFraming.split(data, encoding: encoding, base64Text: base64Text)
        var messages: [ProtobufMessage] = split.frames.flatMap { frame -> [ProtobufMessage] in
            if let error = frame.error { return [ProtobufMessage(error: error)] }
            switch frame.kind {
            case .trailers(let text): return [ProtobufMessage(trailers: text)]
            case .message(let payload): return decodeProtobuf(payload)
            }
        }
        if let error = split.error { messages.append(ProtobufMessage(error: error)) }
        return messages
    }

    /// `decode_raw`-style text of the messages; several are headed `# message n`, trailers `# trailers`.
    public static func protobufText(_ messages: [ProtobufMessage]) -> String {
        var blocks: [String] = []
        var n = 0
        for message in messages {
            if let trailers = message.trailers {
                blocks.append("# trailers\n" + trailers.trimmingCharacters(in: .whitespacesAndNewlines))
                continue
            }
            var lines: [String] = []
            if messages.count > 1, message.fields != nil {
                n += 1
                lines.append("# message \(n)")
            }
            if let fields = message.fields { lines.append(ProtobufDecoder.text(fields)) }
            if let error = message.error { lines.append("# error: \(error)") }
            blocks.append(lines.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
    }

    private mutating func setInlineText(_ data: Data) {
        inlineTextTruncated = data.count > Self.maxInlineTextBytes
        inlineText = Self.text(data.prefix(Self.maxInlineTextBytes))
    }

    /// UTF-8 text, tolerating a multi-byte sequence cut at the end.
    static func text(_ data: Data) -> String {
        for trim in 0...3 where data.count > trim {
            if let s = String(data: data.dropLast(trim), encoding: .utf8) { return s }
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The whole decoded body as text: pretty-printed when it is JSON, `decode_raw`-style when it is protobuf.
    /// Used for copy, the full-text viewer and Diff.
    public func fullText() -> String {
        if let json { return json.serialized(pretty: true) }
        if !protobuf.isEmpty { return Self.protobufText(protobuf) }
        return Self.text(decoded.data)
    }

    /// One line above the body, e.g. "br · 12 KB → 80 KB · truncated", or nil when there is nothing to say.
    public var summary: String? {
        var parts: [String] = []
        let size = { (n: Int) in ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
        if !decoded.appliedEncodings.isEmpty {
            parts.append(decoded.appliedEncodings.joined(separator: "+") + " · \(size(storedSize)) → \(size(decoded.data.count))")
        }
        if decoded.truncated { parts.append("showing the first \(size(decoded.data.count)) only") }
        if let error = decoded.error { parts.append("not decoded: \(error)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// One decoded protobuf message, a gRPC-Web trailer frame, or why a message could not be decoded.
public struct ProtobufMessage: Sendable, Hashable {
    public var fields: [ProtobufField]?
    public var error: String?
    /// The text of a gRPC-Web trailer frame.
    public var trailers: String?

    public init(fields: [ProtobufField]? = nil, error: String? = nil, trailers: String? = nil) {
        self.fields = fields
        self.error = error
        self.trailers = trailers
    }
}
