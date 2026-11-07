import Foundation
import ProxyModel

public struct MultipartPart: Equatable, Sendable {
    public var headers: [HeaderField]
    public var data: Data

    /// `name` from `Content-Disposition`.
    public var name: String? { disposition["name"] }
    /// `filename` from `Content-Disposition`.
    public var filename: String? { disposition["filename"] }
    public var contentType: String? { headers.value(for: "Content-Type") }

    var disposition: [String: String] {
        headers.value(for: "Content-Disposition").map { ContentSniffer.parse($0).params } ?? [:]
    }
}

public struct MultipartBody: Equatable, Sendable {
    public var parts: [MultipartPart]
    /// The closing boundary was never found (cut-off or malformed body).
    public var incomplete: Bool
}

public enum MultipartParser {
    /// Splits a multipart body. Accepts CRLF or bare LF line endings and ignores the preamble.
    public static func parse(_ data: Data, boundary: String) -> MultipartBody {
        let bytes = [UInt8](data)
        let delimiter = Array("--\(boundary)".utf8)
        var parts: [MultipartPart] = []
        guard var cursor = find(delimiter, in: bytes, from: 0) else { return MultipartBody(parts: [], incomplete: true) }
        while true {
            var i = cursor + delimiter.count
            if i + 1 < bytes.count, bytes[i] == 0x2D, bytes[i + 1] == 0x2D { return MultipartBody(parts: parts, incomplete: false) }
            // Skip transport padding and the line break after the delimiter.
            while i < bytes.count, bytes[i] != 0x0A { i += 1 }
            i += 1
            guard i <= bytes.count, let next = find(delimiter, in: bytes, from: i) else {
                if i < bytes.count { parts.append(part(bytes[i...])) }
                return MultipartBody(parts: parts, incomplete: true)
            }
            var end = next
            if end > i, bytes[end - 1] == 0x0A { end -= 1 }
            if end > i, bytes[end - 1] == 0x0D { end -= 1 }
            parts.append(part(bytes[i..<end]))
            cursor = next
        }
    }

    /// Finds a delimiter that starts the input or a line.
    static func find(_ needle: [UInt8], in hay: [UInt8], from start: Int) -> Int? {
        guard needle.count <= hay.count else { return nil }
        var i = start
        while i + needle.count <= hay.count {
            if hay[i] == needle[0], (i == 0 || hay[i - 1] == 0x0A), hay[i..<i + needle.count].elementsEqual(needle) { return i }
            i += 1
        }
        return nil
    }

    static func part(_ slice: ArraySlice<UInt8>) -> MultipartPart {
        var headers: [HeaderField] = []
        var i = slice.startIndex
        while i < slice.endIndex {
            var lineEnd = i
            while lineEnd < slice.endIndex, slice[lineEnd] != 0x0A { lineEnd += 1 }
            var contentEnd = lineEnd
            if contentEnd > i, slice[contentEnd - 1] == 0x0D { contentEnd -= 1 }
            let line = String(decoding: slice[i..<contentEnd], as: UTF8.self)
            i = min(lineEnd + 1, slice.endIndex)
            if line.isEmpty { break }
            if let colon = line.firstIndex(of: ":") {
                headers.append(HeaderField(name: String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                                           value: String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
            }
        }
        return MultipartPart(headers: headers, data: Data(slice[i...]))
    }
}
