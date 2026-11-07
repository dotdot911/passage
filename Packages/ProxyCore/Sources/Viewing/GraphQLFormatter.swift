import Foundation
import ProxyModel

/// One GraphQL operation sent in a request, as the detail view shows it.
public struct GraphQLRequest: Sendable, Equatable {
    public var operationName: String?
    public var query: String
    /// The `variables` value, in its original key order.
    public var variables: JSONNode?

    public init(operationName: String?, query: String, variables: JSONNode?) {
        self.operationName = operationName
        self.query = query
        self.variables = variables
    }

    /// The operations in a GET (URL parameters) or POST (JSON object, or array for a batch) request; empty when
    /// the request is not GraphQL.
    public static func parse(method: String, url: String, body: Data) -> [GraphQLRequest] {
        switch method.uppercased() {
        case "GET":
            let params = GraphQLOperation.queryParameters(url)
            guard let query = params["query"] else { return [] }
            return [GraphQLRequest(operationName: params["operationName"].flatMap { $0.isEmpty ? nil : $0 }, query: query,
                                   variables: params["variables"].flatMap { try? JSONNode.parse($0) })]
        case "POST":
            guard body.count <= GraphQLOperation.maxBodyBytes, let root = try? JSONNode.parse(body) else { return [] }
            switch root {
            case .object: return request(root).map { [$0] } ?? []
            case .array(let items):
                let requests = items.compactMap(request)
                return requests.count == items.count ? requests : []
            default: return []
            }
        default:
            return []
        }
    }

    private static func request(_ node: JSONNode) -> GraphQLRequest? {
        guard case .object(let members) = node else { return nil }
        func member(_ key: String) -> JSONNode? { members.first { $0.key == key }?.value }
        guard case .string(let query)? = member("query") else { return nil }
        var name: String?
        if case .string(let s)? = member("operationName"), !s.isEmpty { name = s }
        var variables = member("variables")
        // Some clients send variables as a JSON string.
        if case .string(let s)? = variables { variables = (try? JSONNode.parse(s)) ?? variables }
        if variables == .null { variables = nil }
        return GraphQLRequest(operationName: name, query: query, variables: variables)
    }
}

public enum GraphQLFormatter {
    /// Re-indents a query by two spaces per `{}` level, one selection per line. Arguments, list values and input
    /// objects inside `()` or `[]` stay on one line. Strings, block strings and comments are kept verbatim.
    public static func format(_ query: String) -> String {
        var lines: [String] = []
        var line = ""
        var lineIndent = 0
        var indent = 0
        // Depth of `(` and `[`; inside them everything stays on the current line.
        var inline = 0
        // For each open `{`: true when it was opened inline (an input object value).
        var braces: [Bool] = []
        var blankBeforeNext = false
        var prev: GraphQLToken?
        var prevPrev: GraphQLToken?

        func flush() {
            if !line.isEmpty { lines.append(String(repeating: "  ", count: lineIndent) + line) }
            line = ""
        }
        func put(_ s: String, space: Bool) {
            if line.isEmpty {
                if blankBeforeNext && indent == 0 && !lines.isEmpty { lines.append("") }
                blankBeforeNext = false
                lineIndent = indent
            } else if space {
                line += " "
            }
            line += s
        }

        for token in GraphQLToken.tokenize(query) {
            let afterSpread = prev?.text == "..."
            let spreadOn = prevPrev?.text == "..." && prev?.text == "on"
            let glued = ["(", "[", "$", "@"].contains(prev?.text ?? "") || (afterSpread && token.text != "on") || prev?.text == "{" && braces.last == true
            switch (token.kind, token.text) {
            case (.comment, _):
                put(token.text, space: true)
                flush()
            case (.punctuator, "{"):
                if inline > 0 {
                    put("{", space: !glued)
                    braces.append(true)
                } else {
                    put("{", space: true)
                    flush()
                    indent += 1
                    braces.append(false)
                }
            case (.punctuator, "}"):
                if braces.popLast() == true {
                    put("}", space: false)
                } else {
                    flush()
                    indent = max(0, indent - 1)
                    put("}", space: false)
                    flush()
                    if indent == 0 { blankBeforeNext = true }
                }
            case (.punctuator, "("):
                put("(", space: prev?.kind != .name && !glued)
                inline += 1
            case (.punctuator, "["):
                put("[", space: !glued)
                inline += 1
            case (.punctuator, ")"), (.punctuator, "]"):
                inline = max(0, inline - 1)
                put(token.text, space: false)
            case (.punctuator, ","):
                // Outside arguments a comma only separates selections, which already get their own lines.
                if inline > 0 { put(",", space: false) }
            case (.punctuator, ":"), (.punctuator, "!"):
                put(token.text, space: false)
            default:
                let startsSelection = token.kind != .punctuator || token.text == "..."
                let continues = [":", "@", "$", "=", "|"].contains(prev?.text ?? "") || afterSpread || spreadOn
                if inline == 0 && indent > 0 && startsSelection && !continues { flush() }
                put(token.text, space: !glued)
            }
            prevPrev = prev
            prev = token
        }
        flush()
        return lines.joined(separator: "\n")
    }
}
