import Foundation

/// Recognises GraphQL requests and names their operation, e.g. "query GetUser".
public enum GraphQLOperation {
    /// Request bodies larger than this are not inspected.
    public static let maxBodyBytes = 256 * 1024

    /// Whether a request could be GraphQL, decided before its body arrives: the engine buffers the body only then.
    public static func mightBeGraphQL(method: String, url: String, contentType: String?) -> Bool {
        switch method.uppercased() {
        case "POST": return isJSON(contentType)
        case "GET": return queryParameters(url)["query"] != nil
        default: return false
        }
    }

    /// The operation label, `batch (n): A, B, C, …` for a batch, or nil when the request is not GraphQL.
    public static func detect(method: String, url: String, contentType: String?, body: Data) -> String? {
        switch method.uppercased() {
        case "GET":
            let params = queryParameters(url)
            guard let query = params["query"] else { return nil }
            return label(query: query, operationName: params["operationName"])
        case "POST":
            guard isJSON(contentType), !body.isEmpty, body.count <= maxBodyBytes,
                  let json = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else { return nil }
            if let object = json as? [String: Any] { return label(object) }
            guard let array = json as? [Any], !array.isEmpty else { return nil }
            var names: [String] = []
            for element in array {
                guard let object = element as? [String: Any], let query = object["query"] as? String,
                      let op = operation(in: query, named: object["operationName"] as? String) else { return nil }
                names.append(op.name ?? "(anonymous)")
            }
            return "batch (\(names.count)): " + names.prefix(3).joined(separator: ", ") + (names.count > 3 ? ", …" : "")
        default:
            return nil
        }
    }

    /// The type ("query", "mutation", "subscription") and name of the operation a document runs, or nil when the
    /// text holds no operation (so `{"query": "shoes"}` from a search API is not taken for GraphQL).
    public static func operation(in query: String, named operationName: String?) -> (type: String, name: String?)? {
        let ops = definitions(query)
        guard let first = ops.first else { return nil }
        let wanted = operationName.flatMap { $0.isEmpty ? nil : $0 }
        let op = wanted.flatMap { name in ops.first { $0.name == name } } ?? first
        return (op.type, wanted ?? op.name)
    }

    private static func label(_ object: [String: Any]) -> String? {
        guard let query = object["query"] as? String else { return nil }
        return label(query: query, operationName: object["operationName"] as? String)
    }

    private static func label(query: String, operationName: String?) -> String? {
        guard let op = operation(in: query, named: operationName) else { return nil }
        return "\(op.type) \(op.name ?? "(anonymous)")"
    }

    /// Operation definitions in document order; a shorthand `{ … }` is an anonymous query.
    private static func definitions(_ query: String) -> [(type: String, name: String?)] {
        var ops: [(type: String, name: String?)] = []
        var depth = 0
        // Between a definition keyword and the `{` that opens its selection set.
        var inHeader = false
        var expectName = false
        for token in GraphQLToken.tokenize(query, keepComments: false) {
            switch token.text {
            case "{", "(", "[":
                if depth == 0 && token.text == "{" {
                    if !inHeader { ops.append(("query", nil)) }
                    inHeader = false
                }
                expectName = false
                depth += 1
            case "}", ")", "]":
                depth = max(0, depth - 1)
            default:
                guard depth == 0, token.kind == .name else { expectName = false; continue }
                if expectName {
                    ops[ops.count - 1].name = token.text
                    expectName = false
                } else if !inHeader, ["query", "mutation", "subscription"].contains(token.text) {
                    ops.append((token.text, nil))
                    inHeader = true
                    expectName = true
                } else if !inHeader, token.text == "fragment" {
                    inHeader = true
                }
            }
        }
        return ops
    }

    private static func isJSON(_ contentType: String?) -> Bool {
        guard let contentType else { return true }
        let mime = contentType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        return mime.isEmpty || mime.contains("json")
    }

    /// Decoded URL query parameters (first value wins), with `+` read as a space.
    public static func queryParameters(_ url: String) -> [String: String] {
        guard let items = URLComponents(string: url)?.percentEncodedQueryItems else { return [:] }
        var params: [String: String] = [:]
        for item in items where params[item.name] == nil {
            let value = item.value?.replacingOccurrences(of: "+", with: "%20")
            params[item.name.removingPercentEncoding ?? item.name] = value.flatMap { $0.removingPercentEncoding ?? $0 } ?? ""
        }
        return params
    }
}

/// One lexical token of a GraphQL document. Every non-blank character of the input lands in exactly one token.
public struct GraphQLToken: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case name, punctuator, string, blockString, number, comment, other }

    public var kind: Kind
    public var text: String

    public init(_ kind: Kind, _ text: String) { self.kind = kind; self.text = text }

    /// Splits a document into tokens. Whitespace is dropped, commas are kept as punctuators, and an unterminated
    /// string runs to the end of its line (a block string to the end of the input).
    public static func tokenize(_ source: String, keepComments: Bool = true) -> [GraphQLToken] {
        let b = Array(source.utf8)
        var tokens: [GraphQLToken] = []
        var i = 0
        func text(_ from: Int, _ to: Int) -> String { String(decoding: b[from..<to], as: UTF8.self) }
        func isNameStart(_ c: UInt8) -> Bool { c == UInt8(ascii: "_") || (c | 0x20 >= UInt8(ascii: "a") && c | 0x20 <= UInt8(ascii: "z")) }
        func isDigit(_ c: UInt8) -> Bool { c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") }
        func at(_ j: Int, _ s: String) -> Bool { j + s.utf8.count <= b.count && Array(b[j..<j + s.utf8.count]) == Array(s.utf8) }
        while i < b.count {
            let c = b[i]
            let start = i
            switch c {
            case 0x20, 0x09, 0x0A, 0x0D:
                i += 1
            case UInt8(ascii: "#"):
                while i < b.count && b[i] != 0x0A && b[i] != 0x0D { i += 1 }
                if keepComments { tokens.append(.init(.comment, text(start, i))) }
            case UInt8(ascii: "\""):
                if at(i, "\"\"\"") {
                    i += 3
                    while i < b.count && !at(i, "\"\"\"") { i += at(i, "\\\"\"\"") ? 4 : 1 }
                    i = min(b.count, i + 3)
                    tokens.append(.init(.blockString, text(start, i)))
                } else {
                    i += 1
                    while i < b.count && b[i] != UInt8(ascii: "\"") && b[i] != 0x0A && b[i] != 0x0D {
                        i += b[i] == UInt8(ascii: "\\") && i + 1 < b.count && b[i + 1] != 0x0A ? 2 : 1
                    }
                    if i < b.count && b[i] == UInt8(ascii: "\"") { i += 1 }
                    tokens.append(.init(.string, text(start, i)))
                }
            case UInt8(ascii: "."):
                i += at(i, "...") ? 3 : 1
                tokens.append(.init(i - start == 3 ? .punctuator : .other, text(start, i)))
            case _ where isNameStart(c):
                while i < b.count && (isNameStart(b[i]) || isDigit(b[i])) { i += 1 }
                tokens.append(.init(.name, text(start, i)))
            case _ where isDigit(c) || c == UInt8(ascii: "-"):
                i += 1
                while i < b.count && (isDigit(b[i]) || isNameStart(b[i]) || [UInt8(ascii: "."), UInt8(ascii: "+"), UInt8(ascii: "-")].contains(b[i])) { i += 1 }
                tokens.append(.init(.number, text(start, i)))
            case _ where "!$&():=@[]{}|,".utf8.contains(c):
                i += 1
                tokens.append(.init(.punctuator, text(start, i)))
            default:
                // A whole UTF-8 sequence (BOM, stray symbol) becomes one token.
                i += 1
                while i < b.count && b[i] & 0xC0 == 0x80 { i += 1 }
                if !(i - start == 3 && at(start, "\u{FEFF}")) { tokens.append(.init(.other, text(start, i))) }
            }
        }
        return tokens
    }
}
