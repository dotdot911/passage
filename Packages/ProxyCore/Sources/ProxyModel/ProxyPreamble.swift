import Foundation

/// The first line the macOS system extension writes on each loopback connection to the app: where the
/// intercepted flow was going and which app opened it. JSON on one line, ended by "\n".
public struct ProxyPreamble: Codable, Hashable, Sendable {
    /// Proves the connection comes from the extension; the app picks a new one each time the proxy starts.
    public var token: String
    /// The IP address the client connected to, as text.
    public var address: String
    public var port: UInt16
    /// The name the client resolved, when the system knows it.
    public var hostname: String?
    /// The signing identifier of the app that opened the connection.
    public var app: String?
    public var pid: Int32?

    /// Longer first lines are refused, so a stray client cannot make the app buffer without end.
    public static let maxLength = 4096

    public init(token: String, address: String, port: UInt16, hostname: String? = nil, app: String? = nil, pid: Int32? = nil) {
        self.token = token; self.address = address; self.port = port
        self.hostname = hostname; self.app = app; self.pid = pid
    }

    public func encoded() -> Data {
        var data = (try? JSONEncoder().encode(self)) ?? Data()
        data.append(0x0A)
        return data
    }

    /// Decodes one line, without its "\n".
    public static func decode(_ line: some Collection<UInt8>) -> ProxyPreamble? {
        try? JSONDecoder().decode(ProxyPreamble.self, from: Data(line))
    }

    /// The destination as an endpoint, or nil when `address` is not an IPv4 or IPv6 literal.
    public var endpoint: IPEndpoint? {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            return IPEndpoint(address: withUnsafeBytes(of: &v4) { Array($0) }, port: port)
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, address, &v6) == 1 {
            return IPEndpoint(address: withUnsafeBytes(of: &v6) { Array($0) }, port: port)
        }
        return nil
    }
}
