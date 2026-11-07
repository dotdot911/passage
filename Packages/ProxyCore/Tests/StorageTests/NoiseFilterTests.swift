import Foundation
import ProxyModel
@testable import Storage
import Testing

@Suite struct NoiseFilterTests {
    let store: FlowStore

    init() throws {
        store = try FlowStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ps-\(UUID().uuidString)"))
    }

    func flow(_ host: String, method: String? = "GET", status: Int? = 200, state: FlowState = .completed) -> FlowRecord {
        var f = FlowRecord(kind: .https, host: host, ip: "1.2.3.4", port: 443)
        f.method = method
        f.statusCode = status
        f.state = state
        return f
    }

    @Test func appleServicesAreHiddenByDefaultAndCounted() throws {
        try store.upsert([flow("gateway.icloud.com"), flow("apple.com"), flow("token.safebrowsing.apple"),
                          flow("api.example.com"), flow("notapple.com")])
        #expect(Set(try store.flows().map(\.host)) == ["api.example.com", "notapple.com"])
        #expect(try store.hiddenAppleServiceCount(FlowFilter()) == 3)

        var all = FlowFilter()
        all.hideAppleServices = false
        #expect(try store.flows(all).count == 5)
        #expect(try store.hiddenAppleServiceCount(all) == 0)
    }

    @Test func tlsFailuresAreCountedApartFromErrors() throws {
        try store.upsert([
            flow("a.test", status: 404),
            flow("a.test", method: nil, status: nil, state: .failed),
            flow("a.test", method: "CONNECT", status: nil, state: .failed),
            flow("a.test", status: nil, state: .failed),
        ])
        let summary = try #require(try store.domainSummaries().first)
        #expect(summary.errorCount == 2)
        #expect(summary.tlsFailureCount == 2)
    }

    @Test func serverHandshakeFailuresAreErrorsNotPinning() throws {
        var server = flow("down.test", method: nil, status: nil, state: .failed)
        server.error = "\(FlowRecord.upstreamTLSPrefix): connectTimeout"
        var client = flow("down.test", method: nil, status: nil, state: .failed)
        client.error = "\(FlowRecord.clientRejectedPrefix) (bad certificate)"
        try store.upsert([server, client])
        let summary = try #require(try store.domainSummaries().first)
        #expect(summary.errorCount == 1)
        #expect(summary.tlsFailureCount == 1)
    }

    @Test func aSessionShowsOnlyItsImportsWithAppleServices() throws {
        var imported = flow("gateway.icloud.com")
        imported.note = "Imported from Store_test.har"
        var importedWithNote = flow("api.example.com")
        importedWithNote.note = "Imported from Store_test.har · Map Local"
        var otherFile = flow("api.example.com")
        otherFile.note = "Imported from StoreXtest.har"
        try store.upsert([imported, importedWithNote, otherFile, flow("live.example.com")])

        var f = FlowFilter()
        f.session = "Store_test.har"
        #expect(Set(try store.flows(f).map(\.id)) == [imported.id, importedWithNote.id])
        #expect(try store.hiddenAppleServiceCount(f) == 0)
        #expect(f.isDefault)
    }

    @Test func filtersSavedBeforeTheAppleFieldStillDecode() throws {
        let old = #"{"text":"","isRegex":false,"kinds":["http","https","dns"],"showPinned":false,"methods":[],"statusClasses":[],"contentTypes":[],"markedOnly":true}"#
        let f = try JSONDecoder().decode(FlowFilter.self, from: Data(old.utf8))
        #expect(f.kinds == [.http, .https, .dns])
        #expect(f.markedOnly)
        #expect(f.hideAppleServices)
        let round = try JSONDecoder().decode(FlowFilter.self, from: JSONEncoder().encode(f))
        #expect(round == f)
    }
}
