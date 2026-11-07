import Foundation
import ProxyModel

/// HAR 1.2 (http://www.softwareishard.com/blog/har-12-spec/), plus Chrome's `_webSocketMessages`
/// and a `_passage` object for notes, comments and highlights.
public enum HAR {
    public static func write(_ flows: [ArchivedFlow], version: String = "1.0") throws -> Data {
        let doc = Document(log: Log(version: "1.2", creator: Creator(name: "Passage", version: version),
                                    entries: flows.filter(\.isExportable).map(Entry.init)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(doc)
    }

    public static func read(_ data: Data) throws(ArchiveError) -> ImportResult {
        let json: Any
        do { json = try JSONSerialization.jsonObject(with: data) } catch { throw .notJSON(error.localizedDescription) }
        guard let log = (json as? [String: Any])?["log"] as? [String: Any], let entries = log["entries"] as? [Any] else {
            throw .wrongFormat("Not a HAR file: there is no log.entries array.")
        }
        var flows: [ArchivedFlow] = []
        var skipped = 0
        let decoder = JSONDecoder()
        for raw in entries {
            guard let bytes = try? JSONSerialization.data(withJSONObject: raw),
                  let entry = try? decoder.decode(Entry.self, from: bytes), let flow = entry.flow() else {
                skipped += 1
                continue
            }
            flows.append(flow)
        }
        return ImportResult(flows: flows, skipped: skipped)
    }

    // MARK: Model

    struct Document: Codable { var log: Log }
    struct Log: Codable {
        var version: String
        var creator: Creator
        var entries: [Entry]
    }
    struct Creator: Codable { var name: String; var version: String }
    struct NameValue: Codable { var name: String; var value: String }

    struct Entry: Codable {
        var startedDateTime: String
        var time: Double
        var request: Request
        var response: Response
        var cache: [String: String]? = [:]
        var timings: Timings
        var serverIPAddress: String?
        var comment: String?
        var _webSocketMessages: [WebSocketFrame]?
        var _passage: Extra?
    }
    struct Request: Codable {
        var method: String
        var url: String
        var httpVersion: String
        var cookies: [NameValue]? = []
        var headers: [NameValue]
        var queryString: [NameValue]? = []
        var postData: PostData?
        var headersSize: Int? = -1
        var bodySize: Int? = -1
    }
    struct PostData: Codable {
        var mimeType: String
        var text: String?
        var encoding: String?
    }
    struct Response: Codable {
        var status: Int
        var statusText: String? = ""
        var httpVersion: String? = ""
        var cookies: [NameValue]? = []
        var headers: [NameValue]
        var content: Content
        var redirectURL: String? = ""
        var headersSize: Int? = -1
        var bodySize: Int? = -1
    }
    struct Content: Codable {
        var size: Int
        var compression: Int?
        var mimeType: String?
        var text: String?
        var encoding: String?
        var comment: String?
    }
    struct Timings: Codable {
        var blocked: Double? = -1
        var dns: Double? = -1
        var connect: Double? = -1
        var send: Double? = 0
        var wait: Double? = 0
        var receive: Double? = 0
        var ssl: Double? = -1
    }
    struct WebSocketFrame: Codable {
        var type: String
        var time: Double
        var opcode: Int
        var data: String
    }
    struct Extra: Codable {
        var note: String?
        var comment: String?
        var highlight: String?
        var graphQL: String?
        var error: String?
    }
}

// MARK: Writing

extension HAR.Entry {
    init(_ flow: ArchivedFlow) {
        let r = flow.record
        let total = r.endedAt.map { max(0, $0.timeIntervalSince(r.startedAt) * 1000) } ?? -1
        let connect = r.connectMs ?? -1
        let ttfb = r.ttfbMs ?? -1
        startedDateTime = ArchiveDate.string(r.startedAt)
        time = total
        let version = r.httpVersion ?? "HTTP/1.1"
        request = HAR.Request(
            method: r.method ?? "GET", url: r.url ?? "", httpVersion: version,
            headers: r.requestHeaders.map { HAR.NameValue(name: $0.name, value: $0.value) },
            queryString: URLComponents(string: r.url ?? "")?.queryItems?.map { HAR.NameValue(name: $0.name, value: $0.value ?? "") } ?? [],
            postData: flow.requestBody.flatMap { body in
                guard !body.isEmpty else { return nil }
                let (text, encoding, _) = Self.encode(body)
                return HAR.PostData(mimeType: r.requestHeaders.value(for: "Content-Type") ?? "", text: text, encoding: encoding)
            },
            bodySize: r.requestBytes)
        let (text, encoding, cut) = Self.encode(flow.responseBody ?? Data())
        let decodedSize = flow.responseBody?.count ?? 0
        response = HAR.Response(
            status: r.state == .failed && r.statusCode == nil ? 0 : (r.statusCode ?? 0),
            statusText: r.statusCode.map { HTTPURLResponse.localizedString(forStatusCode: $0).capitalized } ?? "",
            httpVersion: version,
            headers: r.responseHeaders.map { HAR.NameValue(name: $0.name, value: $0.value) },
            content: HAR.Content(size: decodedSize, compression: max(0, decodedSize - r.responseBytes),
                                 mimeType: r.responseHeaders.value(for: "Content-Type") ?? "",
                                 text: decodedSize == 0 ? nil : text, encoding: encoding, comment: cut ? "truncated" : nil),
            redirectURL: r.responseHeaders.value(for: "Location") ?? "",
            bodySize: r.responseBytes)
        let wait = ttfb >= 0 ? max(0, ttfb - max(0, connect)) : -1
        timings = HAR.Timings(connect: connect, send: 0, wait: wait, receive: total >= 0 && ttfb >= 0 ? max(0, total - ttfb) : -1)
        serverIPAddress = r.ip.isEmpty ? nil : r.ip
        _webSocketMessages = flow.webSocketMessages.isEmpty ? nil : flow.webSocketMessages.map { m in
            HAR.WebSocketFrame(type: m.direction == .sent ? "send" : "receive", time: m.at.timeIntervalSince1970,
                               opcode: m.opcode.harOpcode,
                               data: m.opcode == .text ? String(decoding: m.payload, as: UTF8.self) : m.payload.base64EncodedString())
        }
        let extra = HAR.Extra(note: r.note, comment: flow.comment, highlight: flow.highlight, graphQL: r.graphQL, error: r.error)
        _passage = [extra.note, extra.comment, extra.highlight, extra.graphQL, extra.error].allSatisfy({ $0 == nil }) ? nil : extra
    }

    /// Text as is, anything else as base64; cut at `maxExportBodyBytes`.
    static func encode(_ body: Data) -> (text: String, encoding: String?, cut: Bool) {
        let cut = body.count > ArchivedFlow.maxExportBodyBytes
        let data = cut ? body.prefix(ArchivedFlow.maxExportBodyBytes) : body
        if ArchivedFlow.isText(data) { return (String(decoding: data, as: UTF8.self), nil, cut) }
        return (data.base64EncodedString(), "base64", cut)
    }
}

// MARK: Reading

extension HAR.Entry {
    func flow() -> ArchivedFlow? {
        guard let started = ArchiveDate.date(startedDateTime),
              var r = ArchivedFlow.record(url: request.url, method: request.method, startedAt: started) else { return nil }
        r.requestHeaders = request.headers.map { HeaderField(name: $0.name, value: $0.value) }
        r.responseHeaders = response.headers.map { HeaderField(name: $0.name, value: $0.value) }
        r.statusCode = response.status > 0 ? response.status : nil
        if response.status <= 0 { r.state = .failed }
        r.httpVersion = Self.version(request.httpVersion)
        if time >= 0 { r.endedAt = started.addingTimeInterval(time / 1000) }
        if let connect = timings.connect, connect >= 0 { r.connectMs = connect }
        let beforeFirstByte = [timings.blocked, timings.dns, timings.connect, timings.send, timings.wait]
            .compactMap { $0 }.filter { $0 > 0 }.reduce(0, +)
        if (timings.wait ?? -1) >= 0 { r.ttfbMs = beforeFirstByte }
        r.ip = serverIPAddress ?? ""
        let requestBody = request.postData.flatMap { Self.decode($0.text, encoding: $0.encoding) }
        let responseBody = Self.decode(response.content.text, encoding: response.content.encoding)
        r.requestBytes = requestBody?.count ?? 0
        r.responseBytes = responseBody?.count ?? max(0, response.content.size)
        if let extra = _passage {
            r.note = extra.note
            r.graphQL = extra.graphQL
            r.error = extra.error
        }
        let messages = (_webSocketMessages ?? []).enumerated().compactMap { i, f -> WebSocketMessage? in
            guard let opcode = WebSocketOpcode(harOpcode: f.opcode) else { return nil }
            let payload = opcode == .text ? Data(f.data.utf8) : (Data(base64Encoded: f.data) ?? Data(f.data.utf8))
            return WebSocketMessage(flowID: r.id, seq: i, at: Date(timeIntervalSince1970: f.time),
                                    direction: f.type == "send" ? .sent : .received, opcode: opcode,
                                    length: payload.count, payload: payload, truncated: false)
        }
        return ArchivedFlow(record: r, requestBody: requestBody, responseBody: responseBody, webSocketMessages: messages,
                            comment: _passage?.comment ?? comment, highlight: _passage?.highlight)
    }

    static func decode(_ text: String?, encoding: String?) -> Data? {
        guard let text, !text.isEmpty else { return nil }
        if encoding?.lowercased() == "base64" { return Data(base64Encoded: text, options: .ignoreUnknownCharacters) }
        return Data(text.utf8)
    }

    /// "HTTP/1.1", "http/2.0", "h2", "HTTP/2" → "HTTP/1.1" or "HTTP/2"; anything else kept as written.
    static func version(_ raw: String) -> String? {
        let v = raw.lowercased()
        if v.isEmpty || v == "unknown" { return nil }
        if v == "h2" || v.hasPrefix("http/2") { return "HTTP/2" }
        if v == "h3" || v.hasPrefix("http/3") { return "HTTP/3" }
        if v.hasPrefix("http/1.1") { return "HTTP/1.1" }
        if v.hasPrefix("http/1.0") { return "HTTP/1.0" }
        return raw
    }
}

extension WebSocketOpcode {
    var harOpcode: Int {
        switch self {
        case .text: 1
        case .binary: 2
        case .close: 8
        case .ping: 9
        case .pong: 10
        }
    }

    init?(harOpcode: Int) {
        switch harOpcode {
        case 1: self = .text
        case 2: self = .binary
        case 8: self = .close
        case 9: self = .ping
        case 10: self = .pong
        default: return nil
        }
    }
}
