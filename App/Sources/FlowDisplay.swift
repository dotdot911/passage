import ProxyModel
import Storage
import SwiftUI

extension FlowRecord {
    /// What the method column shows: the HTTP method, or CONNECT, DNS or TCP.
    var methodText: String {
        if let method { return method }
        switch kind {
        case .dns: return "DNS"
        case .raw: return "TCP"
        case .http: return "HTTP"
        case .https: return "CONNECT"
        }
    }

    /// An HTTPS connection whose exchanges were never decrypted: a CONNECT tunnel, or a TLS handshake that failed.
    var isUndecrypted: Bool { kind == .https && (method == nil || method == "CONNECT") }

    /// Path and query, or `host:port` for a tunnel that was not decrypted.
    var rowPath: String {
        isUndecrypted ? "\(host):\(port)" : pathText
    }
}

/// The status text and color of a flow, for the detail summary, Compare and VoiceOver.
enum StatusBadge {
    static func text(_ flow: FlowRecord) -> String {
        switch flow.state {
        case .active: "In progress"
        case .paused: "Paused"
        case .failed: "Failed"
        case .completed:
            if let code = flow.statusCode, flow.kind == .http || flow.kind == .https { HTTPStatus.text(code) }
            else { "Done" }
        }
    }

    static func color(_ flow: FlowRecord) -> Color {
        switch flow.state {
        case .failed: return .statusError
        case .paused: return .statusWarning
        default:
            guard let code = flow.statusCode else { return .secondary }
            return code >= 500 ? .statusError : code >= 400 ? .statusWarning : code >= 300 || code < 200 ? .secondary : .statusSuccess
        }
    }
}

enum HTTPStatus {
    /// "200 OK", "404 Not Found"…
    static func text(_ code: Int) -> String {
        phrase(code).map { "\(code) \($0)" } ?? "\(code)"
    }

    /// "OK", "Not Found"…, or nil for a code without a known phrase.
    static func phrase(_ code: Int) -> String? {
        let phrases = [
            100: "Continue", 101: "Switching Protocols", 200: "OK", 201: "Created", 202: "Accepted", 204: "No Content",
            206: "Partial Content", 301: "Moved Permanently", 302: "Found", 303: "See Other", 304: "Not Modified",
            307: "Temporary Redirect", 308: "Permanent Redirect", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
            404: "Not Found", 405: "Method Not Allowed", 408: "Request Timeout", 409: "Conflict", 410: "Gone",
            413: "Payload Too Large", 415: "Unsupported Media Type", 422: "Unprocessable Entity", 429: "Too Many Requests",
            500: "Internal Server Error", 501: "Not Implemented", 502: "Bad Gateway", 503: "Service Unavailable",
            504: "Gateway Timeout",
        ]
        return phrases[code]
    }
}

extension MarkColor {
    var swiftUIColor: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        }
    }

    var title: String { rawValue.capitalized }
}

extension FlowRecord {
    var pathText: String {
        if kind == .dns { return note ?? (state == .active ? "Resolving…" : "No answers") }
        if isEncryptedTunnel { return url ?? host }
        if let url, let u = URL(string: url) {
            let q = u.query.map { "?\($0)" } ?? ""
            return (u.path.isEmpty ? "/" : u.path) + q
        }
        return note ?? "\(ip):\(port)"
    }

    /// A decrypted or plain HTTP request with a URL to group by.
    var hasEndpoint: Bool { (kind == .http || kind == .https) && !isUndecrypted && url != nil }

    /// The endpoint section on the domain screen; flows without a URL group under their kind.
    var endpointKey: String { hasEndpoint ? EndpointKey.of(url!) : methodText }

    /// HTTPS that was passed through without decryption: only the host is known.
    var isEncryptedTunnel: Bool { kind == .https && method == "CONNECT" }

    var isWebSocket: Bool { statusCode == 101 && responseHeaders.value(for: "Upgrade")?.lowercased() == "websocket" }

    var durationMs: Double? { endedAt.map { $0.timeIntervalSince(startedAt) * 1000 } }
}

/// Small icons for what changed a flow, read from its note: the symbol of the tool that left it.
enum RuleBadge {
    /// The tool that wrote a note, from the note's wording; nil for notes that are not about a rule.
    static func tool(for note: String) -> RuleTool? {
        if note.hasPrefix("Blocked by rule") { return .blockList }
        if note.hasPrefix("Map Local") { return .mapLocal }
        if note.hasPrefix("Mapped to") { return .mapRemote }
        if note.localizedCaseInsensitiveContains("breakpoint") { return .breakpoint }
        if note.hasPrefix("Throttled") || note.hasPrefix("Dropped by Network Conditions") { return .networkConditions }
        if note.hasPrefix("Spoofed") { return .dnsSpoof }
        if note.hasPrefix("Script") || note.contains("by script") { return .script }
        return nil
    }

    /// The tools that changed a flow, by name, for VoiceOver; nil when none did.
    static func toolTitles(for flow: FlowRecord) -> String? {
        let tools = (flow.note?.components(separatedBy: " · ") ?? []).compactMap(tool(for:)).map(\.title)
        return tools.isEmpty ? nil : tools.joined(separator: ", ")
    }

    static func badges(for flow: FlowRecord) -> [(symbol: AppSymbol, color: Color)] {
        guard let note = flow.note else { return [] }
        var out: [(AppSymbol, Color)] = []
        if note.contains("Sent from Compose") { out.append((.sendFill, .blue)) }
        for tool in note.components(separatedBy: " · ").compactMap(tool(for:)) where !out.contains(where: { $0.0 == tool.symbol }) {
            out.append((tool.symbol, tool.badgeColor))
        }
        return out
    }
}

extension RuleTool {
    var badgeColor: Color {
        switch self {
        case .blockList: .red
        case .mapLocal, .mapRemote: .purple
        case .breakpoint: .orange
        case .networkConditions: .teal
        case .dnsSpoof: .pink
        case .script: .indigo
        case .allowList: .green
        case .noCaching: .gray
        }
    }
}

extension Color {
    /// Status colors for text: the system green, orange and red, darkened in light mode so small text stays readable.
    static let statusSuccess = Color(dynamic: (0x248A3D, 0x30D158), increased: (0x1B6B30, 0x30DB5B))
    static let statusWarning = Color(dynamic: (0xC93400, 0xFF9F0A), increased: (0xA62A00, 0xFFB340))
    static let statusError = Color(dynamic: (0xD70015, 0xFF453A), increased: (0xB0000F, 0xFF6961))

    private init(dynamic: (light: UInt32, dark: UInt32), increased: (light: UInt32, dark: UInt32)) {
        func rgb(_ hex: UInt32) -> (CGFloat, CGFloat, CGFloat) {
            (CGFloat(hex >> 16 & 0xFF) / 255, CGFloat(hex >> 8 & 0xFF) / 255, CGFloat(hex & 0xFF) / 255)
        }
        #if os(iOS)
        self.init(uiColor: UIColor { traits in
            let pair = traits.accessibilityContrast == .high ? increased : dynamic
            let (r, g, b) = rgb(traits.userInterfaceStyle == .dark ? pair.dark : pair.light)
            return UIColor(red: r, green: g, blue: b, alpha: 1)
        })
        #else
        self.init(nsColor: NSColor(name: nil) { appearance in
            let high = appearance.bestMatch(from: [.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) != nil
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let pair = high ? increased : dynamic
            let (r, g, b) = rgb(dark ? pair.dark : pair.light)
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        })
        #endif
    }
}

extension ShapeStyle where Self == Color {
    static var statusSuccess: Color { Color.statusSuccess }
    static var statusWarning: Color { Color.statusWarning }
    static var statusError: Color { Color.statusError }
}

extension BreakpointItem {
    /// How long the tunnel holds a paused message before letting it continue unchanged (`RuleEngine`'s timeout).
    static let timeout: TimeInterval = 300

    var deadline: Date { createdAt.addingTimeInterval(Self.timeout) }

    var title: String { phase == .request ? "Paused Request" : "Paused Response" }
}
