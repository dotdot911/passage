import Foundation

/// A request to send from Compose or Repeat. The same value feeds IPC, history and code generation.
public struct ComposedRequest: Codable, Equatable, Sendable {
    public var method: String
    public var url: String
    /// Sent in this order, duplicates included.
    public var headers: [HeaderField]
    /// Nil when the request has no body, and always nil inside IPC messages (the body travels as a file).
    public var body: Data?

    public init(method: String = "GET", url: String = "", headers: [HeaderField] = [], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    /// Rebuilds the request of a recorded flow. Framing headers are dropped: the stored body is already
    /// de-chunked, and `wireHeaders` adds a `Content-Length` that matches whatever body is finally sent.
    public init(flow: FlowRecord, body: Data?) {
        let headers = flow.requestHeaders.filter {
            !["content-length", "transfer-encoding"].contains($0.name.lowercased())
        }
        self.init(method: flow.method ?? "GET", url: flow.url ?? "", headers: headers,
                  body: body?.isEmpty == false ? body : nil)
    }

    /// Where a request goes, parsed from `url`.
    public struct Target: Equatable, Sendable {
        public var isHTTPS: Bool
        public var host: String
        public var port: Int
        /// Path and query, e.g. `/a/b?c=1` (at least `/`).
        public var requestTarget: String
        /// `host`, plus `:port` when it is not the scheme's default; IPv6 hosts in brackets.
        public var hostHeader: String

        public init(isHTTPS: Bool, host: String, port: Int, requestTarget: String, hostHeader: String) {
            self.isHTTPS = isHTTPS
            self.host = host
            self.port = port
            self.requestTarget = requestTarget
            self.hostHeader = hostHeader
        }
    }

    public enum TargetError: Error, Equatable, CustomStringConvertible {
        case invalidURL, unsupportedScheme(String), missingHost
        public var description: String {
            switch self {
            case .invalidURL: "The URL is not valid."
            case .unsupportedScheme(let s): "Only http and https URLs can be sent (got \"\(s)\")."
            case .missingHost: "The URL has no host."
            }
        }
    }

    public func target() throws(TargetError) -> Target {
        guard let c = URLComponents(string: url.trimmingCharacters(in: .whitespaces)) else { throw .invalidURL }
        let scheme = (c.scheme ?? "").lowercased()
        guard scheme == "http" || scheme == "https" else { throw .unsupportedScheme(c.scheme ?? "") }
        // URLComponents keeps the brackets of an IPv6 literal; sockets want the bare address.
        guard let raw = c.host, !raw.isEmpty else { throw .missingHost }
        let host = raw.hasPrefix("[") && raw.hasSuffix("]") ? String(raw.dropFirst().dropLast()) : raw
        let https = scheme == "https"
        let defaultPort = https ? 443 : 80
        let port = c.port ?? defaultPort
        let path = c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath
        let query = c.percentEncodedQuery.map { "?\($0)" } ?? ""
        let bracketed = host.contains(":") ? "[\(host)]" : host
        return Target(isHTTPS: https, host: host, port: port, requestTarget: path + query,
                      hostHeader: port == defaultPort ? bracketed : "\(bracketed):\(port)")
    }

    /// The headers as they go on the wire: the composed ones, plus `Host` and a body length when missing.
    public func wireHeaders(target: Target, bodyLength: Int) -> [HeaderField] {
        var out = headers
        func has(_ name: String) -> Bool { out.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
        if !has("Host") { out.insert(HeaderField(name: "Host", value: target.hostHeader), at: 0) }
        let framed = has("Content-Length") || has("Transfer-Encoding")
        if !framed && (bodyLength > 0 || ["POST", "PUT", "PATCH"].contains(method.uppercased())) {
            out.append(HeaderField(name: "Content-Length", value: "\(bodyLength)"))
        }
        return out
    }
}
