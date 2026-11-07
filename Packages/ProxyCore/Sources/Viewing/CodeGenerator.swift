import Foundation
import ProxyModel

public enum CodeLanguage: String, CaseIterable, Sendable {
    case curl = "cURL", swift = "Swift", python = "Python", javascript = "JavaScript", kotlin = "Kotlin"
}

/// Turns a request into a snippet that sends it. Binary bodies are read from a `body.bin` file instead of inlined.
public enum CodeGenerator {
    public static func generate(_ request: ComposedRequest, language: CodeLanguage) -> String {
        let body = Body(request.body)
        switch language {
        case .curl: return curl(request, body)
        case .swift: return swift(request, body)
        case .python: return python(request, body)
        case .javascript: return javascript(request, body)
        case .kotlin: return kotlin(request, body)
        }
    }

    enum Body {
        case none, text(String), binary(Int)
        init(_ data: Data?) {
            guard let data, !data.isEmpty else { self = .none; return }
            if let s = String(data: data, encoding: .utf8) { self = .text(s) } else { self = .binary(data.count) }
        }
    }

    /// Duplicate header names merged into one value (for languages that take a dictionary).
    static func merged(_ headers: [HeaderField]) -> [(name: String, value: String)] {
        var order: [String] = []
        var values: [String: (name: String, values: [String])] = [:]
        for h in headers {
            let key = h.name.lowercased()
            if values[key] == nil { order.append(key); values[key] = (h.name, []) }
            values[key]!.values.append(h.value)
        }
        return order.map { (values[$0]!.name, values[$0]!.values.joined(separator: ", ")) }
    }

    /// A double-quoted literal escaping backslash, quote, CR, LF, tab and `extra` characters.
    static func quoted(_ s: String, extra: [Character: String] = [:]) -> String {
        var out = "\""
        for c in s {
            switch c {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out += extra[c] ?? String(c)
            }
        }
        return out + "\""
    }

    static func shell(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }

    static func binaryNote(_ n: Int, comment: String) -> String { "\(comment) \(n) bytes of binary body omitted: save them as body.bin" }

    // MARK: Languages

    static func curl(_ r: ComposedRequest, _ body: Body) -> String {
        var parts: [String] = []
        let method = r.method.uppercased()
        if method != "GET" || !(body.isNone) { parts.append("-X \(method)") }
        parts.append(shell(r.url))
        for h in r.headers { parts.append("-H " + shell("\(h.name): \(h.value)")) }
        switch body {
        case .none: break
        case .text(let s): parts.append("--data-raw " + shell(s))
        case .binary: parts.append("--data-binary @body.bin")
        }
        return "curl " + parts.joined(separator: " \\\n  ")
    }

    static func swift(_ r: ComposedRequest, _ body: Body) -> String {
        var lines = ["var request = URLRequest(url: URL(string: \(quoted(r.url)))!)",
                     "request.httpMethod = \(quoted(r.method.uppercased()))"]
        for h in r.headers { lines.append("request.addValue(\(quoted(h.value)), forHTTPHeaderField: \(quoted(h.name)))") }
        switch body {
        case .none: break
        case .text(let s): lines.append("request.httpBody = Data(\(quoted(s)).utf8)")
        case .binary(let n):
            lines.append(binaryNote(n, comment: "//"))
            lines.append("request.httpBody = try Data(contentsOf: URL(fileURLWithPath: \"body.bin\"))")
        }
        lines += ["let (data, response) = try await URLSession.shared.data(for: request)",
                  "print((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))"]
        return lines.joined(separator: "\n")
    }

    static func python(_ r: ComposedRequest, _ body: Body) -> String {
        var lines = ["import requests", "", "response = requests.request(",
                     "    \(quoted(r.method.uppercased())),", "    \(quoted(r.url)),"]
        let headers = merged(r.headers)
        if !headers.isEmpty {
            lines.append("    headers={")
            for h in headers { lines.append("        \(quoted(h.name)): \(quoted(h.value)),") }
            lines.append("    },")
        }
        switch body {
        case .none: break
        case .text(let s): lines.append("    data=\(quoted(s)).encode(\"utf-8\"),")
        case .binary(let n):
            lines.append("    " + binaryNote(n, comment: "#"))
            lines.append("    data=open(\"body.bin\", \"rb\").read(),")
        }
        lines += [")", "print(response.status_code, response.text)"]
        return lines.joined(separator: "\n")
    }

    static func javascript(_ r: ComposedRequest, _ body: Body) -> String {
        var lines: [String] = []
        if case .binary(let n) = body {
            lines += [binaryNote(n, comment: "//"), "const body = require(\"fs\").readFileSync(\"body.bin\");", ""]
        }
        lines += ["const response = await fetch(\(quoted(r.url)), {", "  method: \(quoted(r.method.uppercased())),"]
        let headers = merged(r.headers)
        if !headers.isEmpty {
            lines.append("  headers: {")
            for h in headers { lines.append("    \(quoted(h.name)): \(quoted(h.value)),") }
            lines.append("  },")
        }
        switch body {
        case .none: break
        case .text(let s): lines.append("  body: \(quoted(s)),")
        case .binary: lines.append("  body,")
        }
        lines += ["});", "console.log(response.status, await response.text());"]
        return lines.joined(separator: "\n")
    }

    static func kotlin(_ r: ComposedRequest, _ body: Body) -> String {
        let q = { (s: String) in quoted(s, extra: ["$": "\\$"]) }
        let contentType = r.headers.value(for: "Content-Type")
        let media = contentType.map { "\(q($0)).toMediaType()" } ?? "null"
        var imports = ["okhttp3.OkHttpClient", "okhttp3.Request"]
        var lines: [String] = []
        let bodyExpr: String
        switch body {
        case .none:
            bodyExpr = "null"
        case .text(let s):
            imports += ["okhttp3.MediaType.Companion.toMediaType", "okhttp3.RequestBody.Companion.toRequestBody"]
            bodyExpr = "\(q(s)).toRequestBody(\(media))"
        case .binary(let n):
            imports += ["java.io.File", "okhttp3.MediaType.Companion.toMediaType", "okhttp3.RequestBody.Companion.asRequestBody"]
            lines.append(binaryNote(n, comment: "//"))
            bodyExpr = "File(\"body.bin\").asRequestBody(\(media))"
        }
        if contentType == nil { imports.removeAll { $0.hasSuffix("toMediaType") } }
        var out = imports.map { "import \($0)" } + [""] + lines
        out += ["val request = Request.Builder()", "    .url(\(q(r.url)))", "    .method(\(q(r.method.uppercased())), \(bodyExpr))"]
        for h in r.headers { out.append("    .addHeader(\(q(h.name)), \(q(h.value)))") }
        out += ["    .build()", "OkHttpClient().newCall(request).execute().use { response ->",
                "    println(\"${response.code} ${response.body?.string()}\")", "}"]
        return out.joined(separator: "\n")
    }
}

extension CodeGenerator.Body {
    var isNone: Bool { if case .none = self { true } else { false } }
}
