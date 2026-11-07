import Foundation

/// The protobuf wire type, the low three bits of a field tag.
public enum ProtobufWireType: Int, Sendable, Hashable {
    case varint = 0, fixed64 = 1, lengthDelimited = 2, startGroup = 3, endGroup = 4, fixed32 = 5
}

/// One field of a message decoded without a schema.
public struct ProtobufField: Sendable, Hashable {
    public var number: Int
    public var wireType: ProtobufWireType
    public var value: ProtobufValue

    public init(number: Int, wireType: ProtobufWireType, value: ProtobufValue) {
        self.number = number
        self.wireType = wireType
        self.value = value
    }
}

/// A field value as far as the wire format tells; length-delimited values are guessed (string, message or bytes).
public indirect enum ProtobufValue: Sendable, Hashable {
    case varint(UInt64)
    case fixed64(UInt64)
    case fixed32(UInt32)
    case bytes(Data)
    /// A nested message, or a group (wire type 3).
    case message([ProtobufField])
    case string(String)
}

public struct ProtobufDecodeError: Error, Equatable, CustomStringConvertible {
    public var message: String
    /// Byte offset in the outermost input.
    public var offset: Int
    public var description: String { "\(message) at byte \(offset)" }
}

/// Decodes protobuf wire format without a schema, like `protoc --decode_raw`.
public enum ProtobufDecoder {
    /// Nested length-delimited values deeper than this are shown as bytes or strings, not parsed as messages.
    public static let maxDepth = 32

    public static func decode(_ data: Data) throws(ProtobufDecodeError) -> [ProtobufField] {
        let bytes = [UInt8](data)
        var reader = Reader(bytes: bytes, position: 0, end: bytes.count)
        return try reader.fields(depth: 0, group: nil)
    }

    /// The fields as indented text: `1: 150`, `2 {` … `}`, strings quoted, bytes escaped as `\xNN`.
    public static func text(_ fields: [ProtobufField]) -> String {
        var lines: [String] = []
        write(fields, indent: 0, to: &lines)
        return lines.joined(separator: "\n")
    }

    private static func write(_ fields: [ProtobufField], indent: Int, to lines: inout [String]) {
        let pad = String(repeating: "  ", count: indent)
        for field in fields {
            if case .message(let children) = field.value {
                lines.append("\(pad)\(field.number) {")
                write(children, indent: indent + 1, to: &lines)
                lines.append("\(pad)}")
            } else {
                lines.append("\(pad)\(field.number): \(display(field.value))")
            }
        }
    }

    /// A scalar for display: varints add their signed readings when they differ (`150 (sint: 75)`), fixed values
    /// add their floating-point reading, strings are quoted and bytes escaped.
    public static func display(_ value: ProtobufValue) -> String {
        switch value {
        case .varint(let n):
            let zigzag = Int64(bitPattern: (n >> 1) ^ (0 &- (n & 1)))
            var notes: [String] = []
            if n > UInt64(Int64.max) { notes.append("int: \(Int64(bitPattern: n))") }
            if n != 0 { notes.append("sint: \(zigzag)") }
            return notes.isEmpty ? "\(n)" : "\(n) (\(notes.joined(separator: ", ")))"
        case .fixed32(let n):
            return "\(n) (float: \(Float(bitPattern: n)))"
        case .fixed64(let n):
            return "\(n) (double: \(Double(bitPattern: n)))"
        case .string(let s):
            return quote(s)
        case .bytes(let d):
            return quote(d)
        case .message(let fields):
            return "{\(fields.count) fields}"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F { out += String(format: "\\x%02x", scalar.value) }
                else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    static func quote(_ data: Data) -> String {
        var out = "\""
        for byte in data {
            switch byte {
            case UInt8(ascii: "\""): out += "\\\""
            case UInt8(ascii: "\\"): out += "\\\\"
            case 0x20...0x7E: out.unicodeScalars.append(Unicode.Scalar(byte))
            default: out += String(format: "\\x%02x", byte)
            }
        }
        return out + "\""
    }

    /// Valid UTF-8 without control characters other than tab, newline and carriage return.
    static func printableString(_ bytes: ArraySlice<UInt8>) -> String? {
        guard let s = String(bytes: bytes, encoding: .utf8) else { return nil }
        let printable = s.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F || $0 == "\n" || $0 == "\r" || $0 == "\t" }
        return printable ? s : nil
    }

    private struct Reader {
        let bytes: [UInt8]
        var position: Int
        let end: Int

        func error(_ message: String, at offset: Int? = nil) -> ProtobufDecodeError {
            ProtobufDecodeError(message: message, offset: offset ?? position)
        }

        mutating func varint() throws(ProtobufDecodeError) -> UInt64 {
            let start = position
            var result: UInt64 = 0
            for shift in stride(from: 0, to: 70, by: 7) {
                guard position < end else { throw error("truncated varint", at: start) }
                let byte = bytes[position]
                position += 1
                result |= UInt64(byte & 0x7F) << UInt64(shift)
                if byte & 0x80 == 0 { return result }
            }
            throw error("varint longer than 10 bytes", at: start)
        }

        mutating func fixed(_ size: Int) throws(ProtobufDecodeError) -> UInt64 {
            guard end - position >= size else { throw error("truncated \(size * 8)-bit value") }
            var result: UInt64 = 0
            for i in 0..<size { result |= UInt64(bytes[position + i]) << UInt64(8 * i) }
            position += size
            return result
        }

        /// Fields up to `end`, or up to the end-group tag of `group`.
        mutating func fields(depth: Int, group: Int?) throws(ProtobufDecodeError) -> [ProtobufField] {
            var fields: [ProtobufField] = []
            while position < end {
                let tagStart = position
                let tag = try varint()
                let number = tag >> 3
                guard number >= 1 && number <= 0x1FFF_FFFF else { throw error("invalid field number \(number)", at: tagStart) }
                guard let wireType = ProtobufWireType(rawValue: Int(tag & 7)) else {
                    throw error("invalid wire type \(tag & 7)", at: tagStart)
                }
                let value: ProtobufValue
                switch wireType {
                case .varint: value = .varint(try varint())
                case .fixed64: value = .fixed64(try fixed(8))
                case .fixed32: value = .fixed32(UInt32(try fixed(4)))
                case .lengthDelimited:
                    let lengthStart = position
                    let length = try varint()
                    guard length <= UInt64(end - position) else { throw error("length \(length) runs past the end", at: lengthStart) }
                    let range = position..<position + Int(length)
                    position = range.upperBound
                    value = guess(range, depth: depth)
                case .startGroup:
                    guard depth < maxDepth else { throw error("groups nested deeper than \(maxDepth)", at: tagStart) }
                    value = .message(try self.fields(depth: depth + 1, group: Int(number)))
                case .endGroup:
                    guard group == Int(number) else { throw error("unexpected end of group \(number)", at: tagStart) }
                    return fields
                }
                fields.append(ProtobufField(number: Int(number), wireType: wireType, value: value))
            }
            if let group { throw error("group \(group) not closed") }
            return fields
        }

        /// Readable text first (a message's own tags for fields 1–3 are control bytes, so real messages rarely pass),
        /// then a nested message that uses every byte, then raw bytes.
        func guess(_ range: Range<Int>, depth: Int) -> ProtobufValue {
            if let s = printableString(bytes[range]) { return .string(s) }
            if depth < maxDepth {
                var nested = Reader(bytes: bytes, position: range.lowerBound, end: range.upperBound)
                if let fields = try? nested.fields(depth: depth + 1, group: nil), !fields.isEmpty { return .message(fields) }
            }
            return .bytes(Data(bytes[range]))
        }
    }
}
