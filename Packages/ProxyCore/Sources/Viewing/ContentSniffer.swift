import Foundation

/// What a body is, as far as choosing a previewer goes.
public enum BodyKind: Equatable, Sendable {
    case json, html, xml, form, text, binary
    case image(format: String)
    case multipart(boundary: String)
    case protobuf(framing: ProtobufFraming)
}

/// How protobuf messages are laid out in a body.
public enum ProtobufFraming: Sendable, Equatable {
    /// The body is one message.
    case none
    /// gRPC or gRPC-Web length-prefixed frames.
    case grpc
    /// gRPC-Web frames, base64 encoded.
    case grpcWebText
}

public enum ContentSniffer {
    /// Decides from the `Content-Type` header first, then from the bytes themselves.
    public static func sniff(contentType: String?, data: Data) -> BodyKind {
        if let kind = fromHeader(contentType, data: data) { return kind }
        return fromBytes(data)
    }

    static func fromHeader(_ contentType: String?, data: Data) -> BodyKind? {
        guard let contentType else { return nil }
        let (mime, params) = parse(contentType)
        if mime.hasPrefix("multipart/") {
            return params["boundary"].map { .multipart(boundary: $0) }
        }
        if mime == "application/x-www-form-urlencoded" { return .form }
        if let framing = protobufFraming(mime) { return .protobuf(framing: framing) }
        if mime.contains("json") { return .json }
        if mime.contains("html") { return .html }
        if mime.hasSuffix("xml") { return .xml } // includes image/svg+xml: shown as text
        if mime.hasPrefix("image/") { return .image(format: imageFormat(data) ?? String(mime.dropFirst(6))) }
        if mime.hasPrefix("text/") || mime.contains("javascript") || mime.contains("css") { return .text }
        return nil
    }

    static func protobufFraming(_ mime: String) -> ProtobufFraming? {
        switch mime {
        case "application/x-protobuf", "application/protobuf", "application/vnd.google.protobuf", "application/x-google-protobuf":
            ProtobufFraming.none
        case "application/grpc", "application/grpc+proto", "application/grpc-web", "application/grpc-web+proto":
            .grpc
        case "application/grpc-web-text", "application/grpc-web-text+proto":
            .grpcWebText
        default:
            nil
        }
    }

    static func fromBytes(_ data: Data) -> BodyKind {
        if let format = imageFormat(data) { return .image(format: format) }
        let head = String(decoding: data.prefix(256), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if head.hasPrefix("{") || head.hasPrefix("[") { return .json }
        if head.hasPrefix("<!doctype html") || head.hasPrefix("<html") { return .html }
        if head.hasPrefix("<?xml") { return .xml }
        return looksLikeText(data) ? .text : .binary
    }

    /// Recognises PNG, JPEG, GIF, WebP and HEIC by their magic bytes.
    static func imageFormat(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(12))
        func at(_ i: Int, _ s: String) -> Bool { b.count >= i + s.utf8.count && Array(b[i..<i + s.utf8.count]) == Array(s.utf8) }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpeg" }
        if at(0, "GIF8") { return "gif" }
        if at(0, "RIFF") && at(8, "WEBP") { return "webp" }
        if at(4, "ftypheic") || at(4, "ftypheix") || at(4, "ftypmif1") { return "heic" }
        return nil
    }

    /// Valid UTF-8 (allowing a sequence cut at the end) with few control characters.
    static func looksLikeText(_ data: Data) -> Bool {
        let sample = data.prefix(4096)
        guard !sample.isEmpty else { return true }
        var decoded: String?
        for trim in 0...3 where sample.count > trim {
            if let s = String(data: sample.dropLast(trim), encoding: .utf8) { decoded = s; break }
        }
        guard let decoded else { return false }
        let controls = decoded.unicodeScalars.filter { $0.value < 0x20 && $0 != "\n" && $0 != "\r" && $0 != "\t" }.count
        return controls * 20 < max(1, decoded.unicodeScalars.count)
    }

    /// Splits `type/subtype; a=b; c="d"` into a lowercased mime type and its parameters.
    public static func parse(_ headerValue: String) -> (mime: String, params: [String: String]) {
        let parts = headerValue.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        var params: [String: String] = [:]
        for part in parts.dropFirst() {
            guard let eq = part.firstIndex(of: "=") else { continue }
            let key = part[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            params[key] = value
        }
        return ((parts.first ?? "").lowercased(), params)
    }
}
