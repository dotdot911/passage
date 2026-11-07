import Foundation

/// The tools that change traffic. Each has a global switch and its own list of rules.
public enum RuleTool: String, Codable, CaseIterable, Sendable {
    case breakpoint, mapLocal, mapRemote, blockList, allowList, dnsSpoof, networkConditions, noCaching, script

    /// Tools switched on until the user changes them; Allow List and Network Conditions affect the whole device.
    public static let enabledByDefault: Set<RuleTool> = [.breakpoint, .mapLocal, .mapRemote, .blockList, .noCaching, .dnsSpoof, .script]
}

/// Which requests a rule applies to.
public struct URLMatch: Codable, Equatable, Hashable, Sendable {
    /// A wildcard (`*` matches anything) over the whole URL, or a regular expression when `isRegex`.
    public var pattern: String
    public var isRegex: Bool
    /// Upper-case method, or nil for any method.
    public var method: String?

    public init(pattern: String, isRegex: Bool = false, method: String? = nil) {
        self.pattern = pattern
        self.isRegex = isRegex
        self.method = method
    }
}

/// Bandwidth and latency applied to one host's connections.
public struct NetworkProfile: Codable, Equatable, Hashable, Sendable {
    /// Towards the device; nil means unlimited.
    public var downloadKbps: Int?
    /// From the device; nil means unlimited.
    public var uploadKbps: Int?
    public var latencyMs: Int
    /// Close every matching connection (100% loss).
    public var dropAll: Bool

    public init(downloadKbps: Int? = nil, uploadKbps: Int? = nil, latencyMs: Int = 0, dropAll: Bool = false) {
        self.downloadKbps = downloadKbps
        self.uploadKbps = uploadKbps
        self.latencyMs = latencyMs
        self.dropAll = dropAll
    }

    public static let presets: [(name: String, profile: NetworkProfile)] = [
        ("3G", NetworkProfile(downloadKbps: 780, uploadKbps: 330, latencyMs: 100)),
        ("Edge", NetworkProfile(downloadKbps: 240, uploadKbps: 200, latencyMs: 400)),
        ("Very bad network", NetworkProfile(downloadKbps: 50, uploadKbps: 50, latencyMs: 1500)),
        ("100% loss", NetworkProfile(dropAll: true)),
    ]
}

public enum RuleAction: Codable, Equatable, Hashable, Sendable {
    case breakpoint(request: Bool, response: Bool)
    /// The body lives in the file `rules/<rule id>.body`.
    case mapLocal(status: Int, headers: [HeaderField])
    /// `scheme://host[:port]` keeps the original path and query; a target with a path replaces the path.
    case mapRemote(target: String)
    case block
    case allow
    /// IPv4 and/or IPv6 literals.
    case dnsSpoof(addresses: [String])
    case networkConditions(NetworkProfile)
    case noCaching
    /// The code lives in the file `rules/<rule id>.js`.
    case script(request: Bool, response: Bool)
}

public struct Rule: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var tool: RuleTool
    public var enabled: Bool
    public var name: String
    public var match: URLMatch
    public var action: RuleAction

    public init(id: UUID = UUID(), tool: RuleTool, enabled: Bool = true, name: String, match: URLMatch, action: RuleAction) {
        self.id = id
        self.tool = tool
        self.enabled = enabled
        self.name = name
        self.match = match
        self.action = action
    }
}

/// A request or response held by a breakpoint, as shown to the app. The body is in `breakpoints/<id>.body`.
public struct BreakpointItem: Codable, Equatable, Identifiable, Sendable {
    public enum Phase: String, Codable, Sendable { case request, response }
    public var id: UUID
    public var flowID: UUID
    public var phase: Phase
    public var ruleName: String
    public var method: String
    public var url: String
    /// Response status; nil in the request phase.
    public var status: Int?
    public var headers: [HeaderField]
    public var createdAt: Date

    public init(id: UUID = UUID(), flowID: UUID, phase: Phase, ruleName: String, method: String, url: String,
                status: Int? = nil, headers: [HeaderField], createdAt: Date = Date()) {
        self.id = id
        self.flowID = flowID
        self.phase = phase
        self.ruleName = ruleName
        self.method = method
        self.url = url
        self.status = status
        self.headers = headers
        self.createdAt = createdAt
    }
}

/// What the user changed at a breakpoint. The body, edited or not, is read back from the item's file.
public struct BreakpointEdit: Codable, Equatable, Sendable {
    public var method: String
    public var url: String
    public var status: Int?
    public var headers: [HeaderField]
    public init(method: String, url: String, status: Int?, headers: [HeaderField]) {
        self.method = method
        self.url = url
        self.status = status
        self.headers = headers
    }
}

public enum BreakpointDecision: Codable, Equatable, Sendable {
    case execute(BreakpointEdit)
    case abort
}
