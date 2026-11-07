import Foundation
import ProxyModel
@testable import Storage
import Testing

@Suite struct ComposeHistoryTests {
    let store: FlowStore

    init() throws {
        store = try FlowStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ps-\(UUID().uuidString)"))
    }

    @Test func keepsNewestFiftyWithBodies() throws {
        let start = Date()
        for i in 0..<55 {
            let r = ComposedRequest(method: "POST", url: "https://a.test/\(i)", headers: [HeaderField(name: "X", value: "\(i)")],
                                    body: Data("b\(i)".utf8))
            try store.addComposeHistory(r, at: start.addingTimeInterval(Double(i)))
        }
        let items = try store.composeHistory()
        #expect(items.count == FlowStore.composeHistoryLimit)
        #expect(items.first?.request.url == "https://a.test/54")
        #expect(items.last?.request.url == "https://a.test/5")
        #expect(items.first?.request.body == Data("b54".utf8))
        #expect(items.first?.request.headers == [HeaderField(name: "X", value: "54")])
    }

    @Test func dropsLargeBodiesAndDeletes() throws {
        let big = Data(count: FlowStore.composeHistoryMaxBody + 1)
        try store.addComposeHistory(ComposedRequest(method: "PUT", url: "https://a.test/big", body: big))
        let item = try #require(try store.composeHistory().first)
        #expect(item.request.body == nil)
        #expect(item.bodyDropped)
        try store.deleteComposeHistory(id: item.id)
        #expect(try store.composeHistory().isEmpty)
    }
}
