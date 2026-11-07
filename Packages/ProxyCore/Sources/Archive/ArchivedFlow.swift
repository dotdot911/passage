import Foundation
import ProxyModel
import Viewing

/// One exchange as it travels between the store and HAR or Charles files. Bodies are always decoded
/// (no Content-Encoding left to undo); headers are kept exactly as recorded.
public struct ArchivedFlow: Sendable, Equatable {
    public var record: FlowRecord
    public var requestBody: Data?
    public var responseBody: Data?
    public var webSocketMessages: [WebSocketMessage]
    public var comment: String?
    /// A `MarkColor` raw value.
    public var highlight: String?

    public init(record: FlowRecord, requestBody: Data? = nil, responseBody: Data? = nil,
                webSocketMessages: [WebSocketMessage] = [], comment: String? = nil, highlight: String? = nil) {
        self.record = record
        self.requestBody = requestBody
        self.responseBody = responseBody
        self.webSocketMessages = webSocketMessages
        self.comment = comment
        self.highlight = highlight
    }

    /// Bodies larger than this are cut when exporting.
    public static let maxExportBodyBytes = 10 * 1024 * 1024

    /// Only decrypted or plain HTTP exchanges are archived: tunnels, raw TCP and DNS have no request to replay.
    public var isExportable: Bool {
        (record.kind == .http || record.kind == .https) && record.method != nil && record.method != "CONNECT" && record.url != nil
    }

    /// The flow as it should be stored after an import: a fresh id, `Content-Encoding` dropped because the
    /// body is already decoded, and a note saying where it came from.
    public func imported(from source: String) -> ArchivedFlow {
        var copy = self
        let id = UUID()
        copy.record.id = id
        copy.record.requestHeaders.removeAll { $0.name.caseInsensitiveCompare("Content-Encoding") == .orderedSame }
        copy.record.responseHeaders.removeAll { $0.name.caseInsensitiveCompare("Content-Encoding") == .orderedSame }
        copy.record.note = ["Imported from \(source)", record.note].compactMap { $0 }.joined(separator: " · ")
        if copy.record.state == .active || copy.record.state == .paused { copy.record.state = .completed }
        copy.webSocketMessages = webSocketMessages.map { var m = $0; m.flowID = id; return m }
        return copy
    }

    /// Fills host, ip, port and kind of a record from its URL.
    static func record(url: String, method: String, startedAt: Date) -> FlowRecord? {
        guard let c = URLComponents(string: url), let scheme = c.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = c.host, !host.isEmpty else { return nil }
        let port = c.port ?? (scheme == "https" ? 443 : 80)
        var r = FlowRecord(startedAt: startedAt, kind: scheme == "https" ? .https : .http, host: host, ip: "", port: port)
        r.method = method.uppercased()
        r.url = url
        r.state = .completed
        return r
    }

    /// Whether `data` is valid UTF-8 text with no NUL bytes, i.e. safe to write as a JSON string.
    static func isText(_ data: Data) -> Bool {
        !data.contains(0) && String(data: data, encoding: .utf8) != nil
    }
}

public enum ArchiveError: Error, Equatable, CustomStringConvertible {
    case notJSON(String)
    case wrongFormat(String)

    public var description: String {
        switch self {
        case .notJSON(let reason): "Not a JSON file: \(reason)"
        case .wrongFormat(let reason): reason
        }
    }
}

/// What an import produced.
public struct ImportResult: Sendable {
    public var flows: [ArchivedFlow]
    /// Entries that could not be read.
    public var skipped: Int

    public init(flows: [ArchivedFlow], skipped: Int) {
        self.flows = flows
        self.skipped = skipped
    }
}

/// Dates in archives: ISO 8601 with or without fractional seconds.
enum ArchiveDate {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()
    private static let lock = NSLock()

    static func string(_ date: Date) -> String { lock.withLock { fractional.string(from: date) } }
    static func date(_ string: String) -> Date? {
        lock.withLock { fractional.date(from: string) ?? plain.date(from: string) }
    }
}

extension ArchivedFlow {
    /// A stored body (still carrying its `Content-Encoding`) decoded for export; the raw bytes when decoding fails.
    public static func decodedBody(_ raw: Data?, headers: [HeaderField]) -> Data? {
        guard let raw, !raw.isEmpty else { return nil }
        let decoded = BodyDecoder.decode(raw, contentEncoding: headers.value(for: "Content-Encoding"),
                                         maxOutput: maxExportBodyBytes + 1)
        return decoded.error == nil || !decoded.appliedEncodings.isEmpty ? decoded.data : raw
    }
}
