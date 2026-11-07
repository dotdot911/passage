import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import ProxyModel

/// Where a request goes when it is not the connection's original destination (Compose, Map Remote, breakpoint edits).
struct UpstreamTarget: Hashable, Sendable {
    var isHTTPS: Bool
    var host: String
    var port: Int
    /// Path and query.
    var requestTarget: String
    /// Value for the `Host` header.
    var hostHeader: String

    init?(url: String) {
        guard let t = try? ComposedRequest(url: url).target() else { return nil }
        self.init(t)
    }

    init(_ t: ComposedRequest.Target) {
        isHTTPS = t.isHTTPS
        host = t.host
        port = t.port
        requestTarget = t.requestTarget
        hostHeader = t.hostHeader
    }

    /// The connection identity, ignoring the request path.
    var endpoint: String { "\(isHTTPS ? "https" : "http")://\(host):\(port)" }
}

/// Opens a connection to a host name (resolved by the system resolver, outside the tunnel), with TLS when asked.
enum UpstreamDialer {
    /// - Parameters:
    ///   - address: connect here instead of resolving the host (DNS Spoofing); TLS still names the host.
    ///   - handlers: added after TLS, inside the channel initializer.
    static func dial(_ target: UpstreamTarget, tls: TLSConfiguration, on loop: EventLoop, address: String? = nil,
                     handlers: @escaping @Sendable (Channel) throws -> Void = { _ in }) -> EventLoopFuture<Channel> {
        var sslContext: NIOSSLContext?
        if target.isHTTPS {
            var config = tls
            config.applicationProtocols = ["http/1.1"]
            do { sslContext = try NIOSSLContext(configuration: config) } catch { return loop.makeFailedFuture(error) }
        }
        // SNI must be a host name, never an IP literal.
        let sni = IPAddressBytes(target.host) == nil ? target.host : nil
        return ClientBootstrap(group: loop)
            .connectTimeout(.seconds(15))
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .channelInitializer { [sslContext] ch in
                ch.eventLoop.makeCompletedFuture {
                    if let sslContext {
                        try ch.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: sslContext, serverHostname: sni))
                    }
                    try handlers(ch)
                }
            }
            .connect(host: address ?? target.host, port: target.port)
    }
}
