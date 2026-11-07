import Foundation
import ProxyModel
import Testing

@Suite struct ComposedRequestTests {
    @Test func parsesTargets() throws {
        let t = try ComposedRequest(url: "https://api.test/v1/users?id=7&q=a%20b").target()
        #expect(t == .init(isHTTPS: true, host: "api.test", port: 443, requestTarget: "/v1/users?id=7&q=a%20b", hostHeader: "api.test"))
        let p = try ComposedRequest(url: "http://127.0.0.1:8080").target()
        #expect(p.port == 8080 && p.requestTarget == "/" && p.hostHeader == "127.0.0.1:8080" && !p.isHTTPS)
        let v6 = try ComposedRequest(url: "http://[::1]:81/x").target()
        #expect(v6.host == "::1" && v6.hostHeader == "[::1]:81")
    }

    @Test func rejectsBadURLs() {
        #expect(throws: ComposedRequest.TargetError.unsupportedScheme("ftp")) { try ComposedRequest(url: "ftp://h/x").target() }
        #expect(throws: ComposedRequest.TargetError.missingHost) { try ComposedRequest(url: "https:///x").target() }
        #expect(throws: ComposedRequest.TargetError.unsupportedScheme("")) { try ComposedRequest(url: "not a url").target() }
    }

    @Test func addsHostAndLengthOnlyWhenMissing() throws {
        let get = ComposedRequest(method: "GET", url: "https://a.test:8443/", headers: [HeaderField(name: "Accept", value: "*/*")])
        #expect(get.wireHeaders(target: try get.target(), bodyLength: 0) ==
                [HeaderField(name: "Host", value: "a.test:8443"), HeaderField(name: "Accept", value: "*/*")])

        let post = ComposedRequest(method: "post", url: "https://a.test/", headers: [HeaderField(name: "host", value: "other")])
        #expect(post.wireHeaders(target: try post.target(), bodyLength: 0) ==
                [HeaderField(name: "host", value: "other"), HeaderField(name: "Content-Length", value: "0")])

        let chunked = ComposedRequest(method: "PUT", url: "https://a.test/", headers: [HeaderField(name: "Transfer-Encoding", value: "chunked")])
        #expect(chunked.wireHeaders(target: try chunked.target(), bodyLength: 5).count == 2)
    }

    @Test func rebuildsFromFlow() {
        var flow = FlowRecord(kind: .https, host: "a.test", ip: "1.1.1.1", port: 443)
        flow.method = "PATCH"
        flow.url = "https://a.test/x"
        flow.requestHeaders = [HeaderField(name: "A", value: "1"), HeaderField(name: "content-length", value: "9"),
                               HeaderField(name: "Transfer-Encoding", value: "chunked")]
        let r = ComposedRequest(flow: flow, body: Data())
        #expect(r == ComposedRequest(method: "PATCH", url: "https://a.test/x", headers: [HeaderField(name: "A", value: "1")], body: nil))
    }
}
