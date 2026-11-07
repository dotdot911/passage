/// Matches hosts against user patterns: "example.com" (exact) or "*.example.com" (any subdomain, and the apex).
public struct HostMatcher: Sendable {
    private let exact: Set<String>
    private let suffixes: [String]

    public init(_ patterns: [String]) {
        var exact = Set<String>(), suffixes: [String] = []
        for raw in patterns {
            let p = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if p.hasPrefix("*.") {
                suffixes.append(String(p.dropFirst(1)))
                exact.insert(String(p.dropFirst(2)))
            } else if !p.isEmpty {
                exact.insert(p)
            }
        }
        self.exact = exact
        self.suffixes = suffixes
    }

    public func matches(_ host: String) -> Bool {
        let h = host.lowercased()
        return exact.contains(h) || suffixes.contains { h.hasSuffix($0) }
    }
}

extension HostMatcher {
    /// Why a TLS connection to `host` is passed through instead of decrypted, or nil to decrypt it.
    public static func bypassReason(_ host: String, excluded: HostMatcher, decryptAll: Bool,
                                    sslProxying: HostMatcher, lowMemory: Bool) -> String? {
        if excluded.matches(host) { return "Excluded from SSL proxying" }
        if !decryptAll && !sslProxying.matches(host) { return "SSL Proxying is off for this host" }
        if lowMemory { return "Low memory: not decrypted" }
        return nil
    }
}
