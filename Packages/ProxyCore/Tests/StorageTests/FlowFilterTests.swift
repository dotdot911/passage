import Foundation
import ProxyModel
@testable import Storage
import Testing

@Suite struct FlowFilterTests {
    let store: FlowStore

    init() throws {
        store = try FlowStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ps-\(UUID().uuidString)"))
    }

    func flow(_ host: String, _ path: String = "/", kind: FlowKind = .https, method: String? = "GET", status: Int? = 200,
              state: FlowState = .completed, contentType: String? = nil, note: String? = nil, ago: TimeInterval = 0) -> FlowRecord {
        var f = FlowRecord(startedAt: Date().addingTimeInterval(-ago), kind: kind, host: host, ip: "1.2.3.4", port: 443)
        f.method = method
        f.url = kind == .http || kind == .https ? "https://\(host)\(path)" : nil
        f.statusCode = status
        f.state = state
        f.note = note
        if let contentType { f.responseHeaders = [HeaderField(name: "content-TYPE", value: contentType)] }
        return f
    }

    func hosts(_ configure: (inout FlowFilter) -> Void) throws -> [String] {
        var filter = FlowFilter()
        configure(&filter)
        return try store.flows(filter).map(\.host)
    }

    @Test func defaultShowsOnlyHTTPAndHidesPinned() throws {
        try store.upsert([
            flow("web.test", ago: 4), flow("dns.test", kind: .dns, ago: 3),
            flow("raw.test", kind: .raw, ago: 2), flow("bank.test", kind: .raw, note: "Pinned: not decrypted", ago: 1),
        ])
        #expect(try hosts { _ in } == ["web.test"])
        #expect(try hosts { $0.kinds.insert(.raw) } == ["raw.test", "web.test"])
        #expect(try hosts { $0.showPinned = true } == ["bank.test", "web.test"])
        #expect(try hosts { $0.kinds = [.dns] } == ["dns.test"])
    }

    @Test func clientFilterAndSummaries() throws {
        var safari = flow("a.test", ago: 3), curl = flow("b.test", ago: 2), curl2 = flow("c.test", ago: 1)
        safari.client = "com.apple.Safari"
        curl.client = "com.apple.curl"
        curl2.client = "com.apple.curl"
        try store.upsert([safari, curl, curl2, flow("none.test", ago: 4)])
        #expect(try hosts { $0.client = "com.apple.curl" } == ["c.test", "b.test"])
        #expect(try store.flow(id: safari.id)?.client == "com.apple.Safari")
        let summaries = try store.clientSummaries()
        #expect(summaries.map(\.client) == ["com.apple.curl", "com.apple.Safari"])
        #expect(summaries.map(\.count) == [2, 1])
    }

    @Test func textMatchesHostOrURLLiterally() throws {
        try store.upsert([flow("api.test", "/v1/users_list", ago: 2), flow("cdn.test", "/img%20a.png", ago: 1)])
        #expect(try hosts { $0.text = "USERS_" } == ["api.test"])
        #expect(try hosts { $0.text = "%20" } == ["cdn.test"])
        #expect(try hosts { $0.text = "_" } == ["api.test"]) // "_" is literal, not a LIKE wildcard
    }

    @Test func regexMatchesAndInvalidRegexThrows() throws {
        try store.upsert([flow("a1.test", "/x", ago: 2), flow("b.test", "/v2/y", ago: 1)])
        #expect(try hosts { $0.text = #"^a\d"#; $0.isRegex = true } == ["a1.test"])
        #expect(try hosts { $0.text = "/V2/"; $0.isRegex = true } == ["b.test"])
        var bad = FlowFilter()
        bad.text = "(unclosed"
        bad.isRegex = true
        #expect(throws: FilterError.self) { try store.flows(bad) }
        #expect(throws: FilterError.self) { try store.domainSummaries(bad) }
    }

    @Test func methodsStatusAndFailures() throws {
        try store.upsert([
            flow("ok.test", ago: 4), flow("post.test", method: "POST", status: 201, ago: 3),
            flow("missing.test", status: 404, ago: 2), flow("down.test", status: nil, state: .failed, ago: 1),
        ])
        #expect(try hosts { $0.methods = ["POST"] } == ["post.test"])
        #expect(try hosts { $0.statusClasses = [.clientError, .failed] } == ["down.test", "missing.test"])
        #expect(try hosts { $0.statusClasses = [.success] } == ["post.test", "ok.test"])
    }

    @Test func contentTypeCategories() throws {
        try store.upsert([
            flow("json.test", contentType: "application/problem+json", ago: 4),
            flow("html.test", contentType: "text/html; charset=utf-8", ago: 3),
            flow("img.test", contentType: "image/png", ago: 2), flow("none.test", ago: 1),
        ])
        #expect(try hosts { $0.contentTypes = [.json] } == ["json.test"])
        #expect(try hosts { $0.contentTypes = [.html, .image] } == ["img.test", "html.test"])
        #expect(try hosts { $0.contentTypes = [.other] } == ["none.test"])
    }

    @Test func marksSurviveUpsertsAndFilterAndCascade() throws {
        var a = flow("a.test", ago: 2)
        let b = flow("b.test", ago: 1)
        try store.upsert([a, b])
        try store.setMark(FlowMark(color: .red, comment: "look"), for: a.id)
        a.statusCode = 500
        try store.upsert([a])
        #expect(try store.marks()[a.id] == FlowMark(color: .red, comment: "look"))
        #expect(try hosts { $0.markedOnly = true } == ["a.test"])

        try store.setMark(FlowMark(), for: a.id)
        #expect(try store.marks().isEmpty)

        try store.setMark(FlowMark(comment: "x"), for: b.id)
        try store.deleteAllFlows()
        #expect(try store.marks().isEmpty)
    }

    @Test func domainSummariesPutFavoritesFirst() throws {
        try store.upsert([
            flow("old.test", ago: 50), flow("old.test", status: 500, ago: 40),
            flow("new.test", ago: 1), flow("dns.test", kind: .dns, ago: 0),
        ])
        var s = try store.domainSummaries()
        #expect(s.map(\.host) == ["new.test", "old.test"])
        #expect(s[1].count == 2 && s[1].errorCount == 1 && !s[1].isFavorite)

        try store.setFavorite("old.test", true)
        s = try store.domainSummaries()
        #expect(s.map(\.host) == ["old.test", "new.test"])
        #expect(s[0].isFavorite)
        #expect(try store.favoriteHosts() == ["old.test"])

        var oneHost = FlowFilter()
        oneHost.host = "old.test"
        #expect(try store.flows(oneHost).count == 2)
        #expect(try store.domainSummaries(oneHost).count == 2) // host is ignored for summaries
    }

    @Test func isDefaultIgnoresTextAndHost() {
        var f = FlowFilter()
        f.text = "x"
        f.host = "h"
        #expect(f.isDefault)
        f.markedOnly = true
        #expect(!f.isDefault)
    }
}
