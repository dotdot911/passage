import HTTPEngine
import NIOCore
import NIOEmbedded
import NIOSSL
import Testing

@Suite struct ClientHelloParserTests {
    /// A real ClientHello produced by BoringSSL, captured from an EmbeddedChannel.
    func clientHello(sni: String?, alpn: [String]) throws -> [UInt8] {
        var config = TLSConfiguration.makeClientConfiguration()
        config.applicationProtocols = alpn
        let handler = try NIOSSLClientHandler(context: NIOSSLContext(configuration: config), serverHostname: sni)
        let channel = EmbeddedChannel(handler: handler)
        _ = try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 443)).wait()
        var out: [UInt8] = []
        while let buf = try channel.readOutbound(as: ByteBuffer.self) { out += buf.readableBytesView }
        _ = try? channel.finish()
        return out
    }

    @Test func extractsSNIAndALPN() throws {
        let bytes = try clientHello(sni: "api.example.com", alpn: ["h2", "http/1.1"])
        #expect(ClientHelloParser.parse(bytes) == .hello(.init(serverName: "api.example.com", alpn: ["h2", "http/1.1"])))
    }

    @Test func helloWithoutSNI() throws {
        let bytes = try clientHello(sni: nil, alpn: [])
        #expect(ClientHelloParser.parse(bytes) == .hello(.init(serverName: nil, alpn: [])))
    }

    @Test func partialRecordNeedsMoreData() throws {
        let bytes = try clientHello(sni: "a.test", alpn: [])
        #expect(ClientHelloParser.parse(Array(bytes.prefix(3))) == .needMoreData)
        #expect(ClientHelloParser.parse(Array(bytes.prefix(bytes.count - 1))) == .needMoreData)
    }

    @Test func plainTextIsNotTLS() {
        #expect(ClientHelloParser.parse(Array("GET / HTTP/1.1\r\n".utf8)) == .notTLS)
        #expect(ClientHelloParser.parse([]) == .needMoreData)
    }
}
