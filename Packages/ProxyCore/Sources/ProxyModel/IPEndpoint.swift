import Foundation

/// An IPv4 or IPv6 address plus port, as seen inside the tunnel.
public struct IPEndpoint: Hashable, Sendable, CustomStringConvertible {
    /// 4 bytes for IPv4, 16 bytes for IPv6, network byte order.
    public let address: [UInt8]
    public let port: UInt16

    public init(address: [UInt8], port: UInt16) {
        precondition(address.count == 4 || address.count == 16, "IP address must be 4 or 16 bytes")
        self.address = address
        self.port = port
    }

    public var isIPv6: Bool { address.count == 16 }

    public var host: String {
        isIPv6 ? IPv6Text(address) : address.map(String.init).joined(separator: ".")
    }

    public var description: String { isIPv6 ? "[\(host)]:\(port)" : "\(host):\(port)" }
}
