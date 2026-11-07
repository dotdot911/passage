import CertKit
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS
import SwiftASN1
import Testing
import X509

@Suite struct CertificateAuthorityTests {
    @Test func leafChainsToRootAndHasSAN() throws {
        let ca = try CertificateAuthority.generate()
        let leaf = try ca.issueLeaf(for: "api.example.com")
        #expect(leaf.issuer == ca.certificate.subject)
        let san = try leaf.extensions.subjectAlternativeNames
        #expect(san?.contains(.dnsName("api.example.com")) == true)
        #expect(ca.certificate.publicKey.isValidSignature(leaf.signature, for: leaf))
    }

    @Test func tlsClientTrustingRootCompletesHandshake() async throws {
        let ca = try CertificateAuthority.generate()
        let group = MultiThreadedEventLoopGroup.singleton

        let serverCtx = try ca.serverContext(for: "api.example.com", alpn: ["http/1.1"])
        let server = try await ServerBootstrap(group: group)
            .childChannelInitializer { ch in
                ch.eventLoop.makeCompletedFuture { try ch.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: serverCtx)) }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        defer { server.close(promise: nil) }

        var clientConfig = TLSConfiguration.makeClientConfiguration()
        clientConfig.trustRoots = .certificates([try NIOSSLCertificate(bytes: ca.rootDER(), format: .der)])
        clientConfig.applicationProtocols = ["http/1.1"]
        let clientCtx = try NIOSSLContext(configuration: clientConfig)
        let handshake = group.next().makePromise(of: String?.self)
        let client = try await ClientBootstrap(group: group)
            .channelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    let tls = try NIOSSLClientHandler(context: clientCtx, serverHostname: "api.example.com")
                    try ch.pipeline.syncOperations.addHandler(tls)
                    try ch.pipeline.syncOperations.addHandler(ALPNProbe(promise: handshake))
                }
            }
            .connect(to: server.localAddress!).get()
        defer { client.close(promise: nil) }
        #expect(try await handshake.futureResult.get() == "http/1.1")
    }
}

private final class ALPNProbe: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let promise: EventLoopPromise<String?>
    init(promise: EventLoopPromise<String?>) { self.promise = promise }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let e = event as? TLSUserEvent, case .handshakeCompleted(let proto) = e { promise.succeed(proto) }
        context.fireUserInboundEventTriggered(event)
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { promise.fail(error) }
}
