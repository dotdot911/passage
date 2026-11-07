import Foundation

/// A compiled JSONPath query: `$`, `.key`, `['key']`, `[n]`, `[-n]`, `[*]`, `.*`, `..key`,
/// `[a,b]`, `[start:end]`, `[?(@.k OP v)]` and `[?(@.k)]`.
public struct JSONPath: Sendable {
    public struct Match: Equatable, Sendable {
        /// Normalised location, e.g. `$.items[2].name` or `$['odd key']`.
        public var path: String
        public var node: JSONNode
    }

    public struct SyntaxError: Error, Equatable, CustomStringConvertible {
        public var message: String
        /// Character offset in the query.
        public var offset: Int
        public var description: String { "\(message) at position \(offset)" }
    }

    indirect enum Selector: Equatable, Sendable {
        case name(String)
        case wildcard
        case index(Int)
        case slice(Int?, Int?)
        case union([Selector])
        case filter(Filter)
    }

    struct Segment: Equatable, Sendable {
        var recursive: Bool
        var selector: Selector
    }

    enum Op: String, Sendable { case eq = "==", ne = "!=", lt = "<", le = "<=", gt = ">", ge = ">=" }

    struct Filter: Equatable, Sendable {
        /// Names and indexes after `@`.
        var path: [Selector]
        /// Nil for an existence test.
        var comparison: (op: Op, value: JSONNode)?

        static func == (a: Filter, b: Filter) -> Bool {
            a.path == b.path && a.comparison?.op == b.comparison?.op && a.comparison?.value == b.comparison?.value
        }
    }

    let segments: [Segment]

    public init(_ query: String) throws(SyntaxError) {
        var parser = PathParser(chars: Array(query))
        segments = try parser.parse()
    }

    public func evaluate(_ root: JSONNode) -> [Match] {
        var current = [Match(path: "$", node: root)]
        for segment in segments {
            var next: [Match] = []
            for match in current {
                let targets = segment.recursive ? Self.descendants(match) : [match]
                for t in targets { next += Self.apply(segment.selector, to: t) }
            }
            current = next
        }
        return current
    }

    /// The match itself followed by every value below it, depth first.
    static func descendants(_ m: Match) -> [Match] {
        var out = [m]
        for child in children(m) { out += descendants(child) }
        return out
    }

    static func children(_ m: Match) -> [Match] {
        switch m.node {
        case .object(let members): members.map { Match(path: m.path + key($0.key), node: $0.value) }
        case .array(let items): items.enumerated().map { Match(path: m.path + "[\($0.offset)]", node: $0.element) }
        default: []
        }
    }

    /// The path component for an object key: `.name`, or `['odd key']` when it is not an identifier.
    public static func key(_ k: String) -> String {
        let identifier = !k.isEmpty && k.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } && !k.first!.isNumber
        return identifier ? ".\(k)" : "['\(k.replacingOccurrences(of: "'", with: "\\'"))']"
    }

    static func apply(_ selector: Selector, to m: Match) -> [Match] {
        switch selector {
        case .name(let name):
            guard case .object(let members) = m.node else { return [] }
            return members.filter { $0.key == name }.map { Match(path: m.path + key($0.key), node: $0.value) }
        case .wildcard:
            return children(m)
        case .index(let i):
            guard case .array(let items) = m.node else { return [] }
            let idx = i < 0 ? items.count + i : i
            guard items.indices.contains(idx) else { return [] }
            return [Match(path: m.path + "[\(idx)]", node: items[idx])]
        case .slice(let start, let end):
            guard case .array(let items) = m.node else { return [] }
            func clamp(_ v: Int?, _ dflt: Int) -> Int {
                guard let v else { return dflt }
                return min(max(v < 0 ? items.count + v : v, 0), items.count)
            }
            let s = clamp(start, 0), e = clamp(end, items.count)
            guard s < e else { return [] }
            return (s..<e).map { Match(path: m.path + "[\($0)]", node: items[$0]) }
        case .union(let selectors):
            return selectors.flatMap { apply($0, to: m) }
        case .filter(let filter):
            return children(m).filter { filter.matches($0.node) }
        }
    }
}

extension JSONPath.Filter {
    func matches(_ node: JSONNode) -> Bool {
        var targets = [JSONPath.Match(path: "", node: node)]
        for selector in path { targets = targets.flatMap { JSONPath.apply(selector, to: $0) } }
        guard let target = targets.first?.node else { return false }
        guard let (op, value) = comparison else { return true }
        switch (target, value) {
        case (.number(let a), .number(let b)):
            guard let x = Double(a), let y = Double(b) else { return false }
            return compare(x, y, op)
        case (.string(let a), .string(let b)):
            return compare(a, b, op)
        default:
            switch op {
            case .eq: return target == value
            case .ne: return target != value
            default: return false
            }
        }
    }

    func compare<T: Comparable>(_ a: T, _ b: T, _ op: JSONPath.Op) -> Bool {
        switch op {
        case .eq: a == b
        case .ne: a != b
        case .lt: a < b
        case .le: a <= b
        case .gt: a > b
        case .ge: a >= b
        }
    }
}

struct PathParser {
    let chars: [Character]
    var i = 0

    func fail(_ message: String) -> JSONPath.SyntaxError { .init(message: message, offset: i) }
    var peek: Character? { i < chars.count ? chars[i] : nil }

    mutating func skipSpaces() { while peek == " " { i += 1 } }

    mutating func expect(_ c: Character) throws(JSONPath.SyntaxError) {
        skipSpaces()
        guard peek == c else { throw fail("Expected '\(c)'") }
        i += 1
    }

    mutating func parse() throws(JSONPath.SyntaxError) -> [JSONPath.Segment] {
        skipSpaces()
        guard peek == "$" else { throw fail("A query starts with '$'") }
        i += 1
        var segments: [JSONPath.Segment] = []
        while true {
            skipSpaces()
            guard let c = peek else { return segments }
            if c == "." {
                i += 1
                let recursive = peek == "."
                if recursive { i += 1 }
                if peek == "[" {
                    guard recursive else { throw fail("Unexpected '['") }
                    segments.append(.init(recursive: true, selector: try bracket()))
                } else if peek == "*" {
                    i += 1
                    segments.append(.init(recursive: recursive, selector: .wildcard))
                } else {
                    segments.append(.init(recursive: recursive, selector: .name(try name())))
                }
            } else if c == "[" {
                segments.append(.init(recursive: false, selector: try bracket()))
            } else {
                throw fail("Unexpected '\(c)'")
            }
        }
    }

    mutating func name() throws(JSONPath.SyntaxError) -> String {
        let start = i
        while let c = peek, c.isLetter || c.isNumber || c == "_" || c == "-" || c == "$" { i += 1 }
        guard i > start else { throw fail("Expected a key name") }
        return String(chars[start..<i])
    }

    mutating func bracket() throws(JSONPath.SyntaxError) -> JSONPath.Selector {
        try expect("[")
        skipSpaces()
        if peek == "*" { i += 1; try expect("]"); return .wildcard }
        if peek == "?" {
            i += 1
            try expect("(")
            let filter = try parseFilter()
            try expect(")")
            try expect("]")
            return .filter(filter)
        }
        var items: [JSONPath.Selector] = []
        while true {
            skipSpaces()
            if peek == "'" || peek == "\"" {
                items.append(.name(try quoted()))
            } else {
                let start = try optionalInt()
                skipSpaces()
                if peek == ":" {
                    i += 1
                    items.append(.slice(start, try optionalInt()))
                } else {
                    guard let start else { throw fail("Expected an index, a slice or a quoted key") }
                    items.append(.index(start))
                }
            }
            skipSpaces()
            guard peek == "," else { break }
            i += 1
        }
        try expect("]")
        return items.count == 1 ? items[0] : .union(items)
    }

    mutating func optionalInt() throws(JSONPath.SyntaxError) -> Int? {
        skipSpaces()
        let start = i
        if peek == "-" { i += 1 }
        while let c = peek, c.isASCII, c.isNumber { i += 1 }
        if i == start { return nil }
        guard let v = Int(String(chars[start..<i])) else { throw fail("Invalid number") }
        return v
    }

    mutating func quoted() throws(JSONPath.SyntaxError) -> String {
        let q = chars[i]
        i += 1
        var out = ""
        while let c = peek, c != q {
            if c == "\\" {
                i += 1
                guard let e = peek else { break }
                out.append(e)
            } else {
                out.append(c)
            }
            i += 1
        }
        guard peek == q else { throw fail("Unterminated string") }
        i += 1
        return out
    }

    mutating func parseFilter() throws(JSONPath.SyntaxError) -> JSONPath.Filter {
        skipSpaces()
        guard peek == "@" else { throw fail("A filter starts with '@'") }
        i += 1
        var path: [JSONPath.Selector] = []
        while true {
            if peek == "." { i += 1; path.append(.name(try name())) }
            else if peek == "[" {
                i += 1
                skipSpaces()
                if peek == "'" || peek == "\"" { path.append(.name(try quoted())) }
                else if let n = try optionalInt() { path.append(.index(n)) }
                else { throw fail("Expected an index or a quoted key") }
                try expect("]")
            } else { break }
        }
        skipSpaces()
        guard let op = try comparisonOp() else { return .init(path: path, comparison: nil) }
        skipSpaces()
        return .init(path: path, comparison: (op, try literal()))
    }

    mutating func comparisonOp() throws(JSONPath.SyntaxError) -> JSONPath.Op? {
        for op in [JSONPath.Op.eq, .ne, .le, .ge, .lt, .gt] {
            let s = Array(op.rawValue)
            if i + s.count <= chars.count, Array(chars[i..<i + s.count]) == s { i += s.count; return op }
        }
        return nil
    }

    mutating func literal() throws(JSONPath.SyntaxError) -> JSONNode {
        if peek == "'" || peek == "\"" { return .string(try quoted()) }
        let start = i
        while let c = peek, c != ")", c != " " { i += 1 }
        let word = String(chars[start..<i])
        switch word {
        case "true": return .bool(true)
        case "false": return .bool(false)
        case "null": return .null
        default:
            guard Double(word) != nil else { i = start; throw fail("Expected a number, string, true, false or null") }
            return .number(word)
        }
    }
}
