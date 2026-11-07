import Foundation
import ProxyModel

/// A compiled `URLMatch`.
public struct CompiledMatch: Sendable {
    let regex: NSRegularExpression
    let method: String?
    let anchored: Bool

    public init(_ match: URLMatch) throws(RuleError) {
        let pattern = match.pattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { throw .emptyPattern }
        method = match.method?.uppercased()
        if match.isRegex {
            anchored = false
            do { regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) } catch {
                throw .invalidRegex(error.localizedDescription)
            }
        } else {
            anchored = true
            let full = pattern.contains("://") ? pattern : "*://" + pattern
            let body = full.split(separator: "*", omittingEmptySubsequences: false)
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: ".*")
            regex = try! NSRegularExpression(pattern: "^" + body + "$", options: [.caseInsensitive, .dotMatchesLineSeparators])
        }
    }

    /// - Parameter method: nil matches regardless of the rule's method (host-level checks).
    public func matches(url: String, method: String?) -> Bool {
        if let wanted = self.method, let method, wanted != method.uppercased() { return false }
        return regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
    }
}

public enum RuleError: Error, Equatable, CustomStringConvertible {
    case emptyPattern, invalidRegex(String), invalidTarget, invalidAddress(String), noAddresses
    public var description: String {
        switch self {
        case .emptyPattern: "Enter a URL pattern."
        case .invalidRegex(let m): "Invalid regular expression: \(m)"
        case .invalidTarget: "The target must be an http or https URL with a host, e.g. https://staging.example.com."
        case .invalidAddress(let a): "\"\(a)\" is not an IPv4 or IPv6 address."
        case .noAddresses: "Enter at least one IP address."
        }
    }
}

/// The enabled rules of the enabled tools, compiled. Immutable; build a new one when rules change.
public struct RuleSet: Sendable {
    struct Entry: Sendable {
        let rule: Rule
        let match: CompiledMatch
    }

    private let entries: [RuleTool: [Entry]]

    public static let empty = RuleSet(rules: [], enabledTools: [])

    /// Rules in display order; disabled rules, disabled tools and invalid patterns are left out.
    public init(rules: [Rule], enabledTools: Set<RuleTool>) {
        var byTool: [RuleTool: [Entry]] = [:]
        for rule in rules where rule.enabled && enabledTools.contains(rule.tool) {
            guard let m = try? CompiledMatch(rule.match) else { continue }
            byTool[rule.tool, default: []].append(Entry(rule: rule, match: m))
        }
        entries = byTool
    }

    public func isEmpty(_ tool: RuleTool) -> Bool { entries[tool]?.isEmpty ?? true }

    /// The first rule of `tool` matching a request.
    public func first(_ tool: RuleTool, url: String, method: String?) -> Rule? {
        entries[tool]?.first { $0.match.matches(url: url, method: method) }?.rule
    }

    /// The first rule of `tool` matching a host, tested as `scheme://host` and `scheme://host/` so that both
    /// `*.example.com` and `example.com/*` match (the rule's method is ignored).
    public func hostRule(_ tool: RuleTool, host: String, scheme: String) -> Rule? {
        entries[tool]?.first {
            $0.match.matches(url: "\(scheme)://\(host)", method: nil) || $0.match.matches(url: "\(scheme)://\(host)/", method: nil)
        }?.rule
    }

    /// True when the Allow List is in effect (switched on and not empty).
    public var allowListActive: Bool { !isEmpty(.allowList) }

    /// Whether a host may be recorded and decrypted. Always true while the Allow List is not in effect.
    public func allows(host: String, scheme: String) -> Bool {
        !allowListActive || hostRule(.allowList, host: host, scheme: scheme) != nil
    }

    /// Checks a rule before it is saved.
    public static func validate(_ rule: Rule) throws(RuleError) {
        _ = try CompiledMatch(rule.match)
        switch rule.action {
        case .mapRemote(let target):
            guard let c = URLComponents(string: target), ["http", "https"].contains(c.scheme?.lowercased() ?? ""),
                  c.host?.isEmpty == false else { throw .invalidTarget }
        case .dnsSpoof(let addresses):
            guard !addresses.isEmpty else { throw .noAddresses }
            for a in addresses where IPAddressBytes(a) == nil { throw .invalidAddress(a) }
        default:
            break
        }
    }

    /// The URL a request is sent to under Map Remote: the target's scheme, host and port; its path when it
    /// has one (other than "/"), otherwise the original path; always the original query.
    public static func mapRemote(_ url: String, to target: String) -> String? {
        guard let original = URLComponents(string: url), var t = URLComponents(string: target) else { return nil }
        if t.percentEncodedPath.isEmpty || t.percentEncodedPath == "/" { t.percentEncodedPath = original.percentEncodedPath }
        t.percentEncodedQuery = original.percentEncodedQuery
        return t.string
    }
}
