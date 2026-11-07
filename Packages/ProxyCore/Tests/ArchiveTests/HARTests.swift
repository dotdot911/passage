@testable import Archive
import Foundation
import ProxyModel
import Testing

@Suite struct HARTests {
    func sample() -> ArchivedFlow {
        var r = FlowRecord(startedAt: Date(timeIntervalSince1970: 1_760_000_000.123), kind: .https, host: "api.test", ip: "1.2.3.4", port: 443)
        r.method = "POST"
        r.url = "https://api.test/v1/items?x=1&y=two"
        r.statusCode = 201
        r.state = .completed
        r.httpVersion = "HTTP/2"
        r.endedAt = r.startedAt.addingTimeInterval(0.25)
        r.connectMs = 40
        r.ttfbMs = 120
        r.requestHeaders = [HeaderField(name: "Content-Type", value: "application/json"), HeaderField(name: "X-A", value: "1"),
                            HeaderField(name: "X-A", value: "2")]
        r.responseHeaders = [HeaderField(name: "Content-Type", value: "application/octet-stream"),
                             HeaderField(name: "Content-Encoding", value: "gzip")]
        r.requestBytes = 13
        r.responseBytes = 3
        r.note = "Map Local: x"
        r.graphQL = "query X"
        return ArchivedFlow(record: r, requestBody: Data(#"{"name":"a"}"#.utf8) + Data([0x0a]), responseBody: Data([0, 1, 2, 255]),
                            webSocketMessages: [], comment: "look", highlight: "red")
    }

    @Test func roundTripKeepsEverythingThatMatters() throws {
        let data = try HAR.write([sample()])
        let result = try HAR.read(data)
        #expect(result.skipped == 0)
        let flow = try #require(result.flows.first)
        let a = sample().record, b = flow.record
        #expect(b.method == "POST" && b.url == a.url && b.host == "api.test" && b.port == 443 && b.kind == .https)
        #expect(b.statusCode == 201 && b.httpVersion == "HTTP/2" && b.ip == "1.2.3.4")
        #expect(abs(b.startedAt.timeIntervalSince(a.startedAt)) < 0.001)
        #expect(abs((b.endedAt ?? .distantPast).timeIntervalSince(a.endedAt!)) < 0.001)
        #expect(b.connectMs == 40 && b.ttfbMs == 120)
        #expect(b.requestHeaders == a.requestHeaders && b.responseHeaders == a.responseHeaders)
        #expect(flow.requestBody == sample().requestBody)
        #expect(flow.responseBody == Data([0, 1, 2, 255]))
        #expect(flow.comment == "look" && flow.highlight == "red" && b.note == "Map Local: x" && b.graphQL == "query X")
    }

    @Test func writesStandardFields() throws {
        let json = try JSONSerialization.jsonObject(with: HAR.write([sample()])) as! [String: Any]
        let log = json["log"] as! [String: Any]
        #expect(log["version"] as? String == "1.2")
        let entry = (log["entries"] as! [[String: Any]])[0]
        let request = entry["request"] as! [String: Any]
        #expect((request["queryString"] as! [[String: String]]) == [["name": "x", "value": "1"], ["name": "y", "value": "two"]])
        #expect((request["postData"] as! [String: Any])["mimeType"] as? String == "application/json")
        let content = (entry["response"] as! [String: Any])["content"] as! [String: Any]
        #expect(content["encoding"] as? String == "base64")
        #expect(content["size"] as? Int == 4)
        #expect((entry["startedDateTime"] as! String).hasPrefix("2025-10-09T08:53:20.123"))
    }

    @Test func skipsTunnelsRawAndDNS() throws {
        var tunnel = sample()
        tunnel.record.method = "CONNECT"
        var dns = sample()
        dns.record.kind = .dns
        let json = try JSONSerialization.jsonObject(with: HAR.write([tunnel, dns, sample()])) as! [String: Any]
        #expect(((json["log"] as! [String: Any])["entries"] as! [Any]).count == 1)
    }

    @Test func webSocketMessagesUseChromesFormat() throws {
        var flow = sample()
        flow.record.statusCode = 101
        flow.webSocketMessages = [
            WebSocketMessage(flowID: flow.record.id, seq: 0, at: Date(timeIntervalSince1970: 10), direction: .sent, opcode: .text,
                             length: 2, payload: Data("hi".utf8), truncated: false),
            WebSocketMessage(flowID: flow.record.id, seq: 1, at: Date(timeIntervalSince1970: 11), direction: .received, opcode: .binary,
                             length: 2, payload: Data([9, 8]), truncated: false),
        ]
        let back = try HAR.read(HAR.write([flow])).flows[0].webSocketMessages
        #expect(back.map(\.direction) == [.sent, .received])
        #expect(back.map(\.payload) == [Data("hi".utf8), Data([9, 8])])
        #expect(back.map(\.opcode) == [.text, .binary])
    }

    @Test func readsAChromeExport() throws {
        let har = """
        {"log":{"version":"1.2","creator":{"name":"WebInspector","version":"537.36"},"pages":[],"entries":[
          {"startedDateTime":"2026-10-21T08:00:00.000Z","time":31.5,"request":{"method":"GET","url":"https://example.com/a?b=1",
           "httpVersion":"http/2.0","headers":[{"name":":authority","value":"example.com"}],"queryString":[],"cookies":[],
           "headersSize":-1,"bodySize":0},"response":{"status":200,"statusText":"","httpVersion":"http/2.0",
           "headers":[{"name":"content-type","value":"text/html"}],"cookies":[],"content":{"size":5,"mimeType":"text/html",
           "text":"hello"},"redirectURL":"","headersSize":-1,"bodySize":-1,"_transferSize":120},"cache":{},
           "timings":{"blocked":1,"dns":-1,"ssl":-1,"connect":-1,"send":0.5,"wait":20,"receive":10},"serverIPAddress":"93.184.216.34",
           "_initiator":{"type":"other"},"_priority":"VeryHigh","_resourceType":"document"},
          {"startedDateTime":"broken"}
        ]}}
        """
        let result = try HAR.read(Data(har.utf8))
        #expect(result.skipped == 1)
        let f = try #require(result.flows.first)
        #expect(f.record.httpVersion == "HTTP/2" && f.record.statusCode == 200 && f.record.host == "example.com")
        #expect(f.responseBody == Data("hello".utf8))
        #expect(f.record.ttfbMs == 21.5)
        #expect(f.record.connectMs == nil)
    }

    @Test func rejectsWhatIsNotHAR() {
        #expect(throws: ArchiveError.self) { try HAR.read(Data("nope".utf8)) }
        #expect(throws: ArchiveError.self) { try HAR.read(Data("{\"a\":1}".utf8)) }
    }

    @Test func importingGivesNewIdsDropsContentEncodingAndNotesTheSource() throws {
        let flow = try HAR.read(HAR.write([sample()])).flows[0].imported(from: "s.har")
        #expect(flow.record.id != sample().record.id)
        #expect(flow.record.responseHeaders.value(for: "Content-Encoding") == nil)
        #expect(flow.record.note == "Imported from s.har · Map Local: x")
    }
}
