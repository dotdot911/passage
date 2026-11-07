import Foundation
import ProxyModel
import Viewing

/// Charles "JSON Session File" (`.chlsj`): an array of transactions. Charles does not document it; the shape
/// follows real Charles 4.x exports. Bodies are written decoded, with `decoded: true` when the headers still
/// name a Content-Encoding.
public enum Charles {
    public static func write(_ flows: [ArchivedFlow]) throws -> Data {
        let items = flows.filter(\.isExportable).map(transaction)
        return try JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted, .withoutEscapingSlashes])
    }

    public static func read(_ data: Data) throws(ArchiveError) -> ImportResult {
        let json: Any
        do { json = try JSONSerialization.jsonObject(with: data) } catch { throw .notJSON(error.localizedDescription) }
        guard let items = json as? [Any] else { throw .wrongFormat("Not a Charles session: the file is not a JSON array.") }
        var flows: [ArchivedFlow] = []
        var skipped = 0
        for item in items {
            if let t = item as? [String: Any], let flow = flow(t) {
                flows.append(flow)
            } else if let t = item as? [String: Any], t["tunnel"] as? Bool == true || (t["method"] as? String) == "CONNECT" {
                continue
            } else {
                skipped += 1
            }
        }
        return ImportResult(flows: flows, skipped: skipped)
    }

    // MARK: Writing

    static func transaction(_ flow: ArchivedFlow) -> [String: Any] {
        let r = flow.record
        let c = URLComponents(string: r.url ?? "")
        let scheme = c?.scheme ?? (r.kind == .https ? "https" : "http")
        let defaultPort = scheme == "https" ? 443 : 80
        let version = r.httpVersion == "HTTP/2" ? "HTTP/2.0" : (r.httpVersion ?? "HTTP/1.1")
        let total = r.endedAt.map { Int(($0.timeIntervalSince(r.startedAt) * 1000).rounded()) }
        let path = c?.percentEncodedPath.isEmpty == false ? c!.percentEncodedPath : "/"
        let query = c?.percentEncodedQuery
        var t: [String: Any] = [:]
        t["status"] = r.state == .failed ? "EXCEPTION" : "COMPLETE"
        t["method"] = r.method ?? "GET"
        t["protocolVersion"] = version
        t["scheme"] = scheme
        t["host"] = r.host
        t["port"] = r.port == defaultPort ? NSNull() : r.port as Any
        t["actualPort"] = r.port
        t["path"] = path
        t["query"] = query ?? NSNull()
        t["tunnel"] = false
        t["keptAlive"] = false
        t["webSocket"] = !flow.webSocketMessages.isEmpty || r.statusCode == 101
        t["remoteAddress"] = "\(r.host)/\(r.ip)"
        var times: [String: Any] = [:]
        times["start"] = localDate(r.startedAt)
        times["requestBegin"] = localDate(r.startedAt)
        times["requestComplete"] = localDate(r.startedAt)
        times["responseBegin"] = r.ttfbMs.map { localDate(r.startedAt.addingTimeInterval($0 / 1000)) } ?? NSNull()
        times["end"] = r.endedAt.map(localDate) ?? NSNull()
        t["times"] = times
        let ttfb = r.ttfbMs.map { Int($0.rounded()) }
        var durations: [String: Any] = ["dns": NSNull(), "ssl": NSNull(), "request": 0]
        durations["total"] = total ?? NSNull()
        durations["connect"] = r.connectMs.map { Int($0.rounded()) } ?? NSNull()
        if let total, let ttfb { durations["response"] = max(0, total - ttfb) } else { durations["response"] = NSNull() }
        durations["latency"] = ttfb.map { $0 - Int((r.connectMs ?? 0).rounded()) } ?? NSNull()
        t["durations"] = durations
        t["totalSize"] = r.requestBytes + r.responseBytes
        if r.httpVersion == "HTTP/2" { t["alpn"] = ["protocol": "h2"] }
        if let error = r.error { t["exception"] = error }
        let notes = [r.note, flow.comment].compactMap { $0 }.joined(separator: "\n")
        if !notes.isEmpty { t["notes"] = notes }
        t["request"] = message(headers: r.requestHeaders, body: flow.requestBody, wireSize: r.requestBytes,
                               firstLine: version == "HTTP/2.0" ? nil : "\(r.method ?? "GET") \(path)\(query.map { "?\($0)" } ?? "") \(version)",
                               status: nil)
        t["response"] = message(headers: r.responseHeaders, body: flow.responseBody, wireSize: r.responseBytes,
                                firstLine: version == "HTTP/2.0" ? nil : r.statusCode.map { "\(version) \($0) \(HTTPURLResponse.localizedString(forStatusCode: $0).capitalized)" },
                                status: r.statusCode)
        return t
    }

    static func message(headers: [HeaderField], body: Data?, wireSize: Int, firstLine: String?, status: Int?) -> [String: Any] {
        let (mime, params) = ContentSniffer.parse(headers.value(for: "Content-Type") ?? "")
        let encoding = headers.value(for: "Content-Encoding")
        var header: [String: Any] = ["headers": headers.map { ["name": $0.name, "value": $0.value] }]
        if let firstLine { header["firstLine"] = firstLine }
        var m: [String: Any] = [
            "sizes": ["headers": 0, "body": wireSize],
            "mimeType": mime.isEmpty ? NSNull() : mime,
            "charset": params["charset"] ?? NSNull(),
            "contentEncoding": encoding ?? NSNull(),
            "header": header,
        ]
        if let status { m["status"] = status }
        if let body, !body.isEmpty {
            let data = body.prefix(ArchivedFlow.maxExportBodyBytes)
            var b: [String: Any] = ArchivedFlow.isText(data)
                ? ["text": String(decoding: data, as: UTF8.self), "charset": params["charset"] ?? "UTF-8"]
                : ["encoding": "base64", "encoded": data.base64EncodedString()]
            if encoding != nil { b["decoded"] = true }
            m["body"] = b
        }
        return m
    }

    /// Charles writes local time with a numeric offset, e.g. `2026-10-21T10:00:00.000+07:00`.
    static func localDate(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f.string(from: date)
    }

    // MARK: Reading

    static func flow(_ t: [String: Any]) -> ArchivedFlow? {
        guard t["tunnel"] as? Bool != true, let host = t["host"] as? String, !host.isEmpty,
              let method = t["method"] as? String, method != "CONNECT" else { return nil }
        let scheme = (t["scheme"] as? String ?? "https").lowercased().replacingOccurrences(of: "wss", with: "https")
            .replacingOccurrences(of: "ws", with: "http")
        let port = int(t["actualPort"]) ?? int(t["port"]) ?? (scheme == "https" ? 443 : 80)
        let path = t["path"] as? String ?? "/"
        let query = (t["query"] as? String).map { "?\($0)" } ?? ""
        let portText = port == (scheme == "https" ? 443 : 80) ? "" : ":\(port)"
        let times = t["times"] as? [String: Any] ?? [:]
        let started = (times["start"] as? String).flatMap(ArchiveDate.date) ?? Date()
        guard var r = ArchivedFlow.record(url: "\(scheme)://\(host)\(portText)\(path)\(query)", method: method, startedAt: started)
        else { return nil }
        let request = t["request"] as? [String: Any] ?? [:]
        let response = t["response"] as? [String: Any] ?? [:]
        r.requestHeaders = headers(request).filter { !$0.name.hasPrefix(":") }
        r.responseHeaders = headers(response).filter { !$0.name.hasPrefix(":") }
        let status = int(response["status"])
        r.statusCode = status.flatMap { $0 > 0 ? $0 : nil }
        if (t["status"] as? String) == "EXCEPTION" || r.statusCode == nil {
            r.state = .failed
            r.error = t["exception"] as? String ?? t["errorMessage"] as? String
        }
        let version = (t["protocolVersion"] as? String ?? "").uppercased()
        r.httpVersion = version.hasPrefix("HTTP/2") ? "HTTP/2" : version.hasPrefix("HTTP/1.0") ? "HTTP/1.0" : "HTTP/1.1"
        if let end = (times["end"] as? String).flatMap(ArchiveDate.date) { r.endedAt = end }
        if let begin = (times["responseBegin"] as? String).flatMap(ArchiveDate.date) { r.ttfbMs = begin.timeIntervalSince(started) * 1000 }
        let durations = t["durations"] as? [String: Any] ?? [:]
        if let connect = int(durations["connect"]), connect >= 0 { r.connectMs = Double(connect) }
        if let remote = t["remoteAddress"] as? String, let slash = remote.lastIndex(of: "/") {
            r.ip = String(remote[remote.index(after: slash)...])
        }
        r.note = t["notes"] as? String
        let requestBody = body(request)
        let responseBody = body(response)
        r.requestBytes = int((request["sizes"] as? [String: Any])?["body"]) ?? requestBody?.count ?? 0
        r.responseBytes = int((response["sizes"] as? [String: Any])?["body"]) ?? responseBody?.count ?? 0
        return ArchivedFlow(record: r, requestBody: requestBody, responseBody: responseBody)
    }

    static func headers(_ message: [String: Any]) -> [HeaderField] {
        ((message["header"] as? [String: Any])?["headers"] as? [[String: Any]] ?? []).compactMap { h in
            guard let name = h["name"] as? String else { return nil }
            return HeaderField(name: name, value: h["value"] as? String ?? "")
        }
    }

    /// Accepts `{text}`, `{encoding: "base64", encoded: "…"}` and `{encoded: true, text: "<base64>"}`;
    /// a gzip stream that is still compressed is inflated.
    static func body(_ message: [String: Any]) -> Data? {
        guard let b = message["body"] as? [String: Any] else { return nil }
        var data: Data?
        if let encoded = b["encoded"] as? String {
            data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)
        } else if b["encoded"] as? Bool == true, let text = b["text"] as? String {
            data = Data(base64Encoded: text, options: .ignoreUnknownCharacters)
        } else if let text = b["text"] as? String {
            data = Data(text.utf8)
        }
        guard let data, !data.isEmpty else { return nil }
        if data.starts(with: [0x1f, 0x8b]) {
            let inflated = BodyDecoder.decode(data, contentEncoding: "gzip")
            if inflated.error == nil { return inflated.data }
        }
        return data
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let n as Int: n
        case let n as Double: Int(n)
        case let s as String: Int(s)
        default: nil
        }
    }
}
