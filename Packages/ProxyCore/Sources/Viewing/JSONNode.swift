import Foundation

/// A parsed JSON value that keeps object key order, duplicate keys and number spelling.
public indirect enum JSONNode: Equatable, Sendable {
    case object([JSONMember])
    case array([JSONNode])
    case string(String)
    /// The number exactly as written, so large integers and decimals lose nothing.
    case number(String)
    case bool(Bool)
    case null
}

public struct JSONMember: Equatable, Sendable {
    public var key: String
    public var value: JSONNode
    public init(_ key: String, _ value: JSONNode) { self.key = key; self.value = value }
}

public struct JSONParseError: Error, Equatable, CustomStringConvertible {
    public var message: String
    /// Byte offset in the input.
    public var offset: Int
    public var description: String { "\(message) at byte \(offset)" }
}

extension JSONNode {
    /// Parsing, printing and querying recurse per level; this keeps them inside a 512 KB thread stack.
    public static let maxDepth = 128

    public static func parse(_ data: Data) throws(JSONParseError) -> JSONNode {
        var parser = JSONParser(bytes: [UInt8](data))
        return try parser.parseDocument()
    }

    public static func parse(_ text: String) throws(JSONParseError) -> JSONNode { try parse(Data(text.utf8)) }

    public var childCount: Int {
        switch self {
        case .object(let m): m.count
        case .array(let a): a.count
        default: 0
        }
    }

    /// Serializes back to JSON; `pretty` indents by two spaces, one member per line.
    public func serialized(pretty: Bool = false) -> String {
        var out = ""
        write(to: &out, pretty: pretty, indent: 0)
        return out
    }

    private func write(to out: inout String, pretty: Bool, indent: Int) {
        let newline = pretty ? "\n" : ""
        func pad(_ n: Int) -> String { pretty ? String(repeating: "  ", count: n) : "" }
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += n
        case .string(let s): out += Self.quote(s)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "[" + newline
            for (i, item) in items.enumerated() {
                out += pad(indent + 1)
                item.write(to: &out, pretty: pretty, indent: indent + 1)
                out += (i < items.count - 1 ? "," : "") + newline
            }
            out += pad(indent) + "]"
        case .object(let members):
            if members.isEmpty { out += "{}"; return }
            out += "{" + newline
            for (i, m) in members.enumerated() {
                out += pad(indent + 1) + Self.quote(m.key) + (pretty ? ": " : ":")
                m.value.write(to: &out, pretty: pretty, indent: indent + 1)
                out += (i < members.count - 1 ? "," : "") + newline
            }
            out += pad(indent) + "}"
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
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

struct JSONParser {
    let bytes: [UInt8]
    var i = 0
    var depth = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { i = 3 } // UTF-8 BOM
    }

    func fail(_ message: String) -> JSONParseError { JSONParseError(message: message, offset: i) }

    mutating func parseDocument() throws(JSONParseError) -> JSONNode {
        let value = try parseValue()
        skipWhitespace()
        guard i == bytes.count else { throw fail("Unexpected data after JSON value") }
        return value
    }

    mutating func skipWhitespace() {
        while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
    }

    mutating func parseValue() throws(JSONParseError) -> JSONNode {
        skipWhitespace()
        guard i < bytes.count else { throw fail("Unexpected end of input") }
        switch bytes[i] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try parseNumber())
        default: throw fail("Unexpected character")
        }
    }

    mutating func literal(_ word: String) throws(JSONParseError) {
        let w = Array(word.utf8)
        guard i + w.count <= bytes.count, Array(bytes[i..<i + w.count]) == w else { throw fail("Invalid literal") }
        i += w.count
    }

    mutating func enter() throws(JSONParseError) {
        depth += 1
        if depth > JSONNode.maxDepth { throw fail("Nesting deeper than \(JSONNode.maxDepth)") }
    }

    mutating func parseObject() throws(JSONParseError) -> JSONNode {
        try enter()
        defer { depth -= 1 }
        i += 1
        var members: [JSONMember] = []
        skipWhitespace()
        if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
        while true {
            skipWhitespace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw fail("Expected a key") }
            let key = try parseString()
            skipWhitespace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw fail("Expected ':'") }
            i += 1
            members.append(JSONMember(key, try parseValue()))
            skipWhitespace()
            guard i < bytes.count else { throw fail("Unexpected end of input") }
            if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
            if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
            throw fail("Expected ',' or '}'")
        }
    }

    mutating func parseArray() throws(JSONParseError) -> JSONNode {
        try enter()
        defer { depth -= 1 }
        i += 1
        var items: [JSONNode] = []
        skipWhitespace()
        if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
        while true {
            items.append(try parseValue())
            skipWhitespace()
            guard i < bytes.count else { throw fail("Unexpected end of input") }
            if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
            if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            throw fail("Expected ',' or ']'")
        }
    }

    mutating func parseString() throws(JSONParseError) -> String {
        i += 1 // opening quote
        var out = [UInt8]()
        while true {
            guard i < bytes.count else { throw fail("Unterminated string") }
            let c = bytes[i]
            if c == UInt8(ascii: "\"") { i += 1; break }
            if c < 0x20 { throw fail("Control character in string") }
            if c != UInt8(ascii: "\\") { out.append(c); i += 1; continue }
            i += 1
            guard i < bytes.count else { throw fail("Unterminated string") }
            let e = bytes[i]
            i += 1
            switch e {
            case UInt8(ascii: "\""): out.append(0x22)
            case UInt8(ascii: "\\"): out.append(0x5C)
            case UInt8(ascii: "/"): out.append(0x2F)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "u"):
                var scalar = try hex4()
                if (0xD800..<0xDC00).contains(scalar), i + 1 < bytes.count,
                   bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                    i += 2
                    let low = try hex4()
                    if (0xDC00..<0xE000).contains(low) {
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    } else {
                        out += Array("\u{FFFD}".utf8)
                        scalar = low
                    }
                }
                out += Array(String(Unicode.Scalar(scalar).map(Character.init) ?? "\u{FFFD}").utf8)
            default: throw fail("Invalid escape")
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    mutating func hex4() throws(JSONParseError) -> UInt32 {
        guard i + 4 <= bytes.count, let v = UInt32(String(decoding: bytes[i..<i + 4], as: UTF8.self), radix: 16) else {
            throw fail("Invalid \\u escape")
        }
        i += 4
        return v
    }

    mutating func parseNumber() throws(JSONParseError) -> String {
        let start = i
        func digits() -> Int {
            let s = i
            while i < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[i]) { i += 1 }
            return i - s
        }
        if bytes[i] == UInt8(ascii: "-") { i += 1 }
        guard i < bytes.count else { throw fail("Invalid number") }
        if bytes[i] == UInt8(ascii: "0") { i += 1 } else if digits() == 0 { throw fail("Invalid number") }
        if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
            i += 1
            guard digits() > 0 else { throw fail("Invalid number") }
        }
        if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
            i += 1
            if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
            guard digits() > 0 else { throw fail("Invalid number") }
        }
        return String(decoding: bytes[start..<i], as: UTF8.self)
    }
}
