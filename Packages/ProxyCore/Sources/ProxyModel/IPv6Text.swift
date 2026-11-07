import Foundation

/// Lowercase IPv6 text with "::" compression of the longest zero run (RFC 5952).
public func IPv6Text(_ a: [UInt8]) -> String {
    precondition(a.count == 16)
    let groups = stride(from: 0, to: 16, by: 2).map { UInt16(a[$0]) << 8 | UInt16(a[$0 + 1]) }
    var bestStart = -1, bestLen = 0, curStart = -1, curLen = 0
    for (i, g) in groups.enumerated() {
        if g == 0 {
            if curStart < 0 { curStart = i; curLen = 0 }
            curLen += 1
            if curLen > bestLen { bestStart = curStart; bestLen = curLen }
        } else { curStart = -1 }
    }
    let hex = groups.map { String($0, radix: 16) }
    guard bestLen >= 2 else { return hex.joined(separator: ":") }
    let head = hex[0..<bestStart].joined(separator: ":")
    let tail = hex[(bestStart + bestLen)...].joined(separator: ":")
    return head + "::" + tail
}

/// Parses an IPv4/IPv6 literal into network-order bytes, or nil for DNS names.
public func IPAddressBytes(_ s: String) -> [UInt8]? {
    var v4 = in_addr()
    if inet_pton(AF_INET, s, &v4) == 1 { return withUnsafeBytes(of: v4) { Array($0) } }
    var v6 = in6_addr()
    if inet_pton(AF_INET6, s, &v6) == 1 { return withUnsafeBytes(of: v6) { Array($0) } }
    return nil
}
