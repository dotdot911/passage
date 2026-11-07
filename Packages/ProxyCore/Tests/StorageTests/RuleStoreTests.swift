import Foundation
import ProxyModel
@testable import Storage
import Testing

@Suite struct RuleStoreTests {
    let store: FlowStore

    init() throws {
        store = try FlowStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ps-\(UUID().uuidString)"))
    }

    func rule(_ name: String, _ tool: RuleTool = .blockList) -> Rule {
        Rule(tool: tool, name: name, match: URLMatch(pattern: "\(name).test"), action: .block)
    }

    @Test func savesUpdatesOrdersAndDeletes() throws {
        var a = rule("a")
        let b = rule("b"), c = rule("c")
        for r in [a, b, c] { try store.saveRule(r) }
        #expect(try store.rules().map(\.name) == ["a", "b", "c"])

        a.enabled = false
        try store.saveRule(a)
        #expect(try store.rules().first == a)

        try store.setRuleOrder([c.id, a.id])
        #expect(try store.rules().map(\.name) == ["c", "a", "b"])

        try FileManager.default.createDirectory(at: store.rulesDirectory, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: store.ruleBodyURL(b.id))
        try store.deleteRule(id: b.id)
        #expect(try store.rules().map(\.name) == ["c", "a"])
        #expect(!FileManager.default.fileExists(atPath: store.ruleBodyURL(b.id).path))
    }

    @Test func enabledToolsDefaultAndPersist() throws {
        #expect(try store.setting(Settings.enabledTools) == RuleTool.enabledByDefault)
        try store.setSetting(Settings.enabledTools, [.allowList])
        #expect(try store.setting(Settings.enabledTools) == [.allowList])
    }
}
