import Foundation
import ProxyModel
import Rules
import Testing

@Suite struct RulesTests {
    func m(_ pattern: String, regex: Bool = false, method: String? = nil) throws -> CompiledMatch {
        try CompiledMatch(URLMatch(pattern: pattern, isRegex: regex, method: method))
    }

    @Test func wildcardMatchesTheWholeURLCaseInsensitively() throws {
        let api = try m("https://api.test/v1/*")
        #expect(api.matches(url: "https://API.test/v1/users?id=1", method: "GET"))
        #expect(api.matches(url: "https://api.test/v1/", method: nil))
        #expect(!api.matches(url: "https://api.test/v2/users", method: "GET"))
        #expect(!api.matches(url: "http://evil.test/?u=https://api.test/v1/x", method: "GET"))
        let exact = try m("https://a.test/x")
        #expect(!exact.matches(url: "https://a.test/xy", method: nil))
    }

    @Test func patternWithoutSchemeMatchesAnyScheme() throws {
        let p = try m("*.example.com/*")
        #expect(p.matches(url: "https://img.example.com/a.png", method: nil))
        #expect(p.matches(url: "dns://a.example.com/", method: nil))
        #expect(!p.matches(url: "https://example.org/", method: nil))
        #expect(try m("*.test").matches(url: "dns://a.test", method: nil))
    }

    @Test func specialCharactersAreLiteral() throws {
        let p = try m("https://a.test/search?q=(1+1)*")
        #expect(p.matches(url: "https://a.test/search?q=(1+1)&x=2", method: nil))
        #expect(!p.matches(url: "https://aXtest/search?q=(1+1)", method: nil))
    }

    @Test func regexAndMethod() throws {
        let p = try m(#"/users/\d+$"#, regex: true, method: "delete")
        #expect(p.matches(url: "https://a.test/users/42", method: "DELETE"))
        #expect(!p.matches(url: "https://a.test/users/42", method: "GET"))
        #expect(p.matches(url: "https://a.test/users/42", method: nil))
        #expect(throws: RuleError.self) { try m("(", regex: true) }
        #expect(throws: RuleError.emptyPattern) { try m("  ") }
    }

    @Test func firstEnabledRuleWinsAndDisabledToolsAreIgnored() {
        let a = Rule(tool: .mapLocal, name: "A", match: URLMatch(pattern: "https://a.test/*"), action: .mapLocal(status: 200, headers: []))
        let off = Rule(tool: .mapLocal, enabled: false, name: "Off", match: URLMatch(pattern: "*"), action: .mapLocal(status: 404, headers: []))
        let b = Rule(tool: .mapLocal, name: "B", match: URLMatch(pattern: "*"), action: .mapLocal(status: 500, headers: []))
        let set = RuleSet(rules: [off, a, b], enabledTools: [.mapLocal])
        #expect(set.first(.mapLocal, url: "https://a.test/x", method: "GET")?.name == "A")
        #expect(set.first(.mapLocal, url: "https://z.test/", method: "GET")?.name == "B")
        #expect(RuleSet(rules: [a], enabledTools: []).first(.mapLocal, url: "https://a.test/x", method: "GET") == nil)
    }

    @Test func hostRulesAndAllowList() {
        let allow = Rule(tool: .allowList, name: "api", match: URLMatch(pattern: "*.api.test"), action: .allow)
        let block = Rule(tool: .blockList, name: "ads", match: URLMatch(pattern: "ads.test"), action: .block)
        let set = RuleSet(rules: [allow, block], enabledTools: [.allowList, .blockList])
        #expect(set.allowListActive)
        #expect(set.allows(host: "v1.api.test", scheme: "https"))
        #expect(!set.allows(host: "google.com", scheme: "https"))
        #expect(set.hostRule(.blockList, host: "ADS.test", scheme: "tcp")?.name == "ads")
        #expect(RuleSet(rules: [allow], enabledTools: []).allows(host: "google.com", scheme: "https"))
    }

    @Test func validation() {
        func rule(_ action: RuleAction) -> Rule { Rule(tool: .mapRemote, name: "r", match: URLMatch(pattern: "*"), action: action) }
        #expect(throws: RuleError.invalidTarget) { try RuleSet.validate(rule(.mapRemote(target: "staging"))) }
        #expect(throws: RuleError.invalidAddress("1.2.3")) { try RuleSet.validate(rule(.dnsSpoof(addresses: ["1.2.3.4", "1.2.3"]))) }
        #expect(throws: RuleError.noAddresses) { try RuleSet.validate(rule(.dnsSpoof(addresses: []))) }
        #expect(throws: Never.self) { try RuleSet.validate(rule(.dnsSpoof(addresses: ["10.0.0.1", "::1"]))) }
    }

    @Test func mapRemoteKeepsOrReplacesThePath() {
        #expect(RuleSet.mapRemote("https://prod.test/v1/a?x=1", to: "http://localhost:8080") == "http://localhost:8080/v1/a?x=1")
        #expect(RuleSet.mapRemote("https://prod.test/v1/a?x=1", to: "https://stg.test/mock") == "https://stg.test/mock?x=1")
    }
}
