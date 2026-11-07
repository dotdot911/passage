import CertKit
import NIOCore
import NIOHTTP1

/// Serves requests addressed to the tunnel's own IP (http(s)://198.18.0.1/...):
/// the CA download used during onboarding and the trust check.
final class InternalSiteHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let ca: CertificateAuthority
    private var uri = "/"
    private var keepAlive = true

    init(ca: CertificateAuthority) { self.ca = ca }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            uri = head.uri
            keepAlive = head.isKeepAlive
        case .body: break
        case .end:
            let (status, type, body) = response(for: uri)
            var h = HTTPHeaders()
            h.add(name: "content-type", value: type)
            h.add(name: "content-length", value: "\(body.count)")
            h.add(name: "x-passage", value: "1")
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: h))), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(context.channel.allocator.buffer(bytes: body)))), promise: nil)
            let keepAlive = self.keepAlive
            let channel = context.channel
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
                if !keepAlive { channel.close(promise: nil) }
            }
        }
    }

    func response(for uri: String) -> (HTTPResponseStatus, String, [UInt8]) {
        switch uri.split(separator: "?").first.map(String.init) ?? uri {
        case "/check":
            return (.ok, "text/plain", Array("ok".utf8))
        case "/ca.cer":
            if let der = try? ca.rootDER() { return (.ok, "application/x-x509-ca-cert", der) }
        case "/ca.mobileconfig":
            if let der = try? ca.rootDER(), let profile = try? ProfileBuilder.rootProfile(der: der) {
                return (.ok, "application/x-apple-aspen-config", Array(profile))
            }
        case "/", "/index.html":
            let html = """
            <html><head><meta name="viewport" content="width=device-width"></head>
            <body style="font-family:-apple-system;padding:24px"><h2>Passage</h2>
            <p><a href="/ca.mobileconfig">Install the Passage CA profile</a></p></body></html>
            """
            return (.ok, "text/html; charset=utf-8", Array(html.utf8))
        default: break
        }
        return (.notFound, "text/plain", Array("not found".utf8))
    }
}
