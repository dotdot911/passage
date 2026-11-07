@testable import Archive
import Foundation
import ProxyModel
import Testing

@Suite struct CharlesTests {
    @Test func roundTrip() throws {
        let flow = HARTests().sample()
        let back = try #require(try Charles.read(Charles.write([flow])).flows.first)
        let a = flow.record, b = back.record
        #expect(b.method == "POST" && b.url == a.url && b.statusCode == 201 && b.httpVersion == "HTTP/2" && b.ip == "1.2.3.4")
        #expect(abs(b.startedAt.timeIntervalSince(a.startedAt)) < 0.001)
        #expect(b.requestHeaders == a.requestHeaders && b.responseHeaders == a.responseHeaders)
        #expect(back.requestBody == flow.requestBody && back.responseBody == flow.responseBody)
        #expect(b.connectMs == 40)
        #expect(abs((b.ttfbMs ?? 0) - 120) < 1)
    }

    @Test func readsTheShapeCharlesWrites() throws {
        let json = """
        [{"status":"COMPLETE","method":"GET","protocolVersion":"HTTP/2.0","scheme":"https","host":"api.example.com","port":null,
          "actualPort":8443,"path":"/v1/users","query":"page=1","tunnel":false,"keptAlive":true,"webSocket":false,
          "remoteAddress":"api.example.com/93.184.216.34","clientAddress":"/127.0.0.1","clientPort":53018,
          "times":{"start":"2026-10-21T10:00:00.000+07:00","requestBegin":"2026-10-21T10:00:00.010+07:00",
            "requestComplete":"2026-10-21T10:00:00.010+07:00","responseBegin":"2026-10-21T10:00:00.090+07:00","end":"2026-10-21T10:00:00.095+07:00"},
          "durations":{"total":95,"dns":2,"connect":5,"ssl":20,"request":0,"response":5,"latency":80},
          "speeds":{"overall":"4210","request":"0","response":"6000"},"totalSize":"400",
          "request":{"sizes":{"handshake":517,"headers":80,"body":0},"mimeType":null,"charset":null,"contentEncoding":null,
            "header":{"headers":[{"name":":method","value":"GET"},{"name":"accept","value":"*/*"}]}},
          "response":{"status":200,"sizes":{"headers":100,"body":40},"mimeType":"application/json","charset":"utf-8","contentEncoding":"gzip",
            "header":{"headers":[{"name":":status","value":"200"},{"name":"content-encoding","value":"gzip"}]},
            "body":{"text":"{\\"users\\":[]}","charset":"utf-8","decoded":true}}},
         {"status":"COMPLETE","method":"CONNECT","host":"x.test","actualPort":443,"tunnel":true},
         {"status":"EXCEPTION","method":"POST","protocolVersion":"HTTP/1.1","scheme":"http","host":"up.test","actualPort":80,
          "path":"/upload","query":null,"exception":"Connection reset","times":{"start":"2026-10-21T10:00:01.000+07:00"},
          "request":{"header":{"firstLine":"POST /upload HTTP/1.1","headers":[]},"body":{"encoding":"base64","encoded":"AAEC"}},
          "response":{"status":-1}},
         {"no":"host"}]
        """
        let result = try Charles.read(Data(json.utf8))
        #expect(result.flows.count == 2 && result.skipped == 1)
        let get = result.flows[0].record
        #expect(get.url == "https://api.example.com:8443/v1/users?page=1" && get.httpVersion == "HTTP/2")
        #expect(get.requestHeaders == [HeaderField(name: "accept", value: "*/*")])
        #expect(result.flows[0].responseBody == Data(#"{"users":[]}"#.utf8))
        #expect(get.ip == "93.184.216.34" && get.connectMs == 5 && get.ttfbMs.map { abs($0 - 90) < 1 } == true)
        let post = result.flows[1]
        #expect(post.record.state == .failed && post.record.error == "Connection reset" && post.requestBody == Data([0, 1, 2]))
    }

    @Test func rejectsWhatIsNotCharles() {
        #expect(throws: ArchiveError.self) { try Charles.read(Data("{\"log\":{}}".utf8)) }
    }
}
