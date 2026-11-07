import Foundation
import GRDB
import ProxyModel

public enum StatusClass: String, Codable, Sendable, CaseIterable {
    case informational, success, redirect, clientError, serverError, failed
}

/// What the flow list shows. Every empty set means "no restriction".
public struct FlowFilter: Codable, Equatable, Sendable {
    /// Matched against host or URL: a case-insensitive substring, or a regex when `isRegex`.
    public var text = ""
    public var isRegex = false
    public var kinds: Set<FlowKind> = [.http, .https]
    /// Raw flows of pinned hosts are shown only when this is on, whatever `kinds` says.
    public var showPinned = false
    public var methods: Set<String> = []
    public var statusClasses: Set<StatusClass> = []
    /// Category of the response `Content-Type`.
    public var contentTypes: Set<ContentCategory> = []
    public var markedOnly = false
    /// Restricts to one host (the domain drill-down).
    public var host: String?
    /// Restricts to the flows of one app (macOS), by signing identifier.
    public var client: String?
    /// Hides Apple's own services (iCloud, App Store, push…), which fill the list on any busy device.
    public var hideAppleServices = true
    /// Shows only the flows imported from this file (an opened session) instead of live traffic.
    public var session: String?

    /// Host suffixes of Apple's system services; each also matches the bare domain.
    public static let appleServiceSuffixes = [
        "apple.com", "icloud.com", "icloud-content.com", "mzstatic.com", "apple-cloudkit.com",
        "cdn-apple.com", "apple-dns.net", "apple-livephotoskit.com", "itunes.com", "apple",
    ]

    public init() {}

    /// Every HTTP and HTTPS flow, Apple's services included: for rule matching and saved sessions, which ignore the list's filter.
    public static var allHTTP: FlowFilter {
        var f = FlowFilter()
        f.hideAppleServices = false
        return f
    }

    private enum CodingKeys: String, CodingKey {
        case text, isRegex, kinds, showPinned, methods, statusClasses, contentTypes, markedOnly, host, client, hideAppleServices, session
    }

    /// Every field is optional so a filter saved by an older version still decodes.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FlowFilter()
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? d.text
        isRegex = try c.decodeIfPresent(Bool.self, forKey: .isRegex) ?? d.isRegex
        kinds = try c.decodeIfPresent(Set<FlowKind>.self, forKey: .kinds) ?? d.kinds
        showPinned = try c.decodeIfPresent(Bool.self, forKey: .showPinned) ?? d.showPinned
        methods = try c.decodeIfPresent(Set<String>.self, forKey: .methods) ?? d.methods
        statusClasses = try c.decodeIfPresent(Set<StatusClass>.self, forKey: .statusClasses) ?? d.statusClasses
        contentTypes = try c.decodeIfPresent(Set<ContentCategory>.self, forKey: .contentTypes) ?? d.contentTypes
        markedOnly = try c.decodeIfPresent(Bool.self, forKey: .markedOnly) ?? d.markedOnly
        host = try c.decodeIfPresent(String.self, forKey: .host)
        client = try c.decodeIfPresent(String.self, forKey: .client)
        hideAppleServices = try c.decodeIfPresent(Bool.self, forKey: .hideAppleServices) ?? d.hideAppleServices
        session = try c.decodeIfPresent(String.self, forKey: .session)
    }

    /// The SQL condition true for Apple service hosts, with its arguments.
    static var appleServiceCondition: (sql: String, arguments: StatementArguments) {
        let sql = appleServiceSuffixes.map { _ in "host = ? OR host LIKE ?" }.joined(separator: " OR ")
        var args = StatementArguments()
        for suffix in appleServiceSuffixes { args += [suffix, "%." + suffix] }
        return ("(\(sql))", args)
    }

    /// True when only the defaults (and possibly `text`/`host`) are set: the filter button shows no badge.
    public var isDefault: Bool {
        var plain = self
        plain.text = ""
        plain.isRegex = false
        plain.host = nil
        plain.client = nil
        plain.session = nil
        return plain == FlowFilter()
    }

    /// Throws `FilterError.invalidRegex` when `text` is not a valid regular expression.
    public func validate() throws {
        guard isRegex, !text.isEmpty else { return }
        do { _ = try RegexCache.shared.regex(text) } catch { throw FilterError.invalidRegex(error.localizedDescription) }
    }

    /// The WHERE clause for the `flow` table, or nil when nothing is filtered.
    func whereClause(includeHost: Bool = true) -> (sql: String, arguments: StatementArguments) {
        var clauses: [String] = []
        var args = StatementArguments()

        if !text.isEmpty {
            if isRegex {
                clauses.append("(host REGEXP ? OR IFNULL(url, '') REGEXP ? OR IFNULL(graphQL, '') REGEXP ?)")
                args += [text, text, text]
            } else {
                let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
                clauses.append("(host LIKE ? ESCAPE '\\' OR url LIKE ? ESCAPE '\\' OR graphQL LIKE ? ESCAPE '\\')")
                args += ["%\(escaped)%", "%\(escaped)%", "%\(escaped)%"]
            }
        }

        let pinned = "(kind = 'raw' AND IFNULL(note, '') LIKE 'Pinned%')"
        var kindClause = kinds.isEmpty ? "0" : "(kind IN (\(placeholders(kinds.count))) AND NOT \(pinned))"
        args += StatementArguments(kinds.map(\.rawValue).sorted())
        if showPinned { kindClause = "(\(kindClause) OR \(pinned))" }
        clauses.append(kindClause)

        if !methods.isEmpty {
            clauses.append("method IN (\(placeholders(methods.count)))")
            args += StatementArguments(methods.sorted())
        }

        if !statusClasses.isEmpty {
            let parts = statusClasses.sorted { $0.rawValue < $1.rawValue }.map { c -> String in
                switch c {
                case .informational: "statusCode BETWEEN 100 AND 199"
                case .success: "statusCode BETWEEN 200 AND 299"
                case .redirect: "statusCode BETWEEN 300 AND 399"
                case .clientError: "statusCode BETWEEN 400 AND 499"
                case .serverError: "statusCode BETWEEN 500 AND 599"
                case .failed: "state = 'failed'"
                }
            }
            clauses.append("(" + parts.joined(separator: " OR ") + ")")
        }

        if !contentTypes.isEmpty {
            // Mirrors ContentCategory(contentType:) on the first Content-Type response header.
            let ct = """
            IFNULL((SELECT lower(json_extract(h.value, '$.value')) FROM json_each(flow.responseHeaders) AS h \
            WHERE lower(json_extract(h.value, '$.name')) = 'content-type' LIMIT 1), '')
            """
            let category = """
            CASE WHEN \(ct) LIKE '%json%' THEN 'json' WHEN \(ct) LIKE '%html%' THEN 'html' \
            WHEN \(ct) LIKE 'image/%' THEN 'image' ELSE 'other' END
            """
            clauses.append("(\(category)) IN (\(placeholders(contentTypes.count)))")
            args += StatementArguments(contentTypes.map(\.rawValue).sorted())
        }

        if markedOnly { clauses.append("id IN (SELECT flowID FROM flowMark)") }

        if let session {
            // Imported flows carry "Imported from <file>", possibly followed by " · " and the original note.
            let escaped = session.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            clauses.append("(note = ? OR note LIKE ? ESCAPE '\\')")
            args += ["Imported from \(session)", "Imported from \(escaped) · %"]
        }

        // A saved session is shown whole: it was recorded with Apple's services in it on purpose.
        if hideAppleServices && session == nil {
            let apple = Self.appleServiceCondition
            clauses.append("NOT \(apple.sql)")
            args += apple.arguments
        }

        if includeHost, let host {
            clauses.append("host = ?")
            args += [host]
        }
        if let client {
            clauses.append("client = ?")
            args += [client]
        }
        return (clauses.joined(separator: " AND "), args)
    }

    private func placeholders(_ n: Int) -> String { Array(repeating: "?", count: n).joined(separator: ", ") }
}

public enum FilterError: Error, Equatable, LocalizedError {
    case invalidRegex(String)
    public var errorDescription: String? {
        switch self { case .invalidRegex(let m): "Invalid regular expression: \(m)" }
    }
}

/// Compiled case-insensitive patterns for the SQL `REGEXP` function.
final class RegexCache: @unchecked Sendable {
    static let shared = RegexCache()
    private let lock = NSLock()
    private var cache: [String: NSRegularExpression] = [:]

    func regex(_ pattern: String) throws -> NSRegularExpression {
        try lock.withLock {
            if let r = cache[pattern] { return r }
            let r = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            if cache.count > 32 { cache.removeAll() }
            cache[pattern] = r
            return r
        }
    }

    /// `value REGEXP pattern` in SQLite calls `regexp(pattern, value)`.
    static let function = DatabaseFunction("regexp", argumentCount: 2, pure: true) { values in
        guard let pattern = String.fromDatabaseValue(values[0]), let value = String.fromDatabaseValue(values[1]) else { return false }
        let r = try RegexCache.shared.regex(pattern)
        return r.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }
}

/// One row of the "by domain" list.
public struct DomainSummary: Equatable, Sendable, FetchableRecord, Decodable, Identifiable {
    public var host: String
    public var count: Int
    public var lastAt: Date
    /// Responses with status 400 or above, plus failed requests; failed TLS handshakes are counted apart.
    public var errorCount: Int
    /// HTTPS connections that failed before any request was decrypted, usually a client rejecting the CA.
    public var tlsFailureCount: Int
    public var isFavorite: Bool
    public var id: String { host }
}

/// One row per app in the Mac sidebar.
public struct ClientSummary: Equatable, Sendable, FetchableRecord, Decodable, Identifiable {
    public var client: String
    public var count: Int
    public var lastAt: Date
    public var id: String { client }
}

public enum MarkColor: String, Codable, Sendable, CaseIterable {
    case red, orange, yellow, green, blue, purple
}

/// The user's highlight and comment on a flow. Kept out of the `flow` table so the extension's upserts never touch it.
public struct FlowMark: Codable, Equatable, Sendable {
    public var color: MarkColor?
    public var comment: String?
    public init(color: MarkColor? = nil, comment: String? = nil) { self.color = color; self.comment = comment }
    public var isEmpty: Bool { color == nil && (comment ?? "").isEmpty }
}
