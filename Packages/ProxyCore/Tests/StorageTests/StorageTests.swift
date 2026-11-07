import Foundation
import GRDB
import ProxyModel
@testable import Storage
import Testing

@Suite struct StorageTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ps-\(UUID().uuidString)")

    func sample(_ host: String, ago seconds: TimeInterval = 0) -> FlowRecord {
        var f = FlowRecord(startedAt: Date().addingTimeInterval(-seconds), kind: .https, host: host, ip: "1.2.3.4", port: 443)
        f.method = "GET"
        f.url = "https://\(host)/path"
        f.requestHeaders = [HeaderField(name: "Accept", value: "*/*")]
        f.state = .completed
        return f
    }

    @Test func upsertReplacesAndQueriesNewestFirst() throws {
        let store = try FlowStore(directory: dir)
        var a = sample("a.test", ago: 10)
        let b = sample("b.test", ago: 5)
        try store.upsert([a, b])
        a.statusCode = 204
        a.state = .completed
        try store.upsert([a])

        let all = try store.flows()
        #expect(all.map(\.host) == ["b.test", "a.test"])
        #expect(all[1].statusCode == 204)
        #expect(all[1].requestHeaders == [HeaderField(name: "Accept", value: "*/*")])
        #expect(try store.flows({ var f = FlowFilter(); f.text = "A.TE"; return f }()).map(\.host) == ["a.test"])
        #expect(try store.flow(id: b.id)?.host == "b.test")
    }

    @Test func recorderCoalescesUpdatesIntoOneWrite() throws {
        let store = try FlowStore(directory: dir)
        let flushes = Counter()
        let recorder = FlowRecorder(store: store) { flushes.increment() }
        var f = sample("c.test")
        recorder.record(f)
        f.statusCode = 200
        recorder.record(f)
        recorder.waitForPendingFlush()
        Thread.sleep(forTimeInterval: 0.15)
        recorder.waitForPendingFlush()

        #expect(try store.flows().first?.statusCode == 200)
        #expect(flushes.value == 1)
    }

    @Test func bodiesStreamToFilesAndQuotaDeletesOldestFlows() throws {
        let store = try FlowStore(directory: dir)
        let old = sample("old.test", ago: 100), new = sample("new.test")
        try store.upsert([old, new])
        for f in [old, new] {
            let w = store.bodies.writer(flowID: f.id, side: .response)
            w.append([UInt8](repeating: 1, count: 600))
            w.append([UInt8](repeating: 2, count: 400))
            w.finish()
        }
        FileBodySink.drain()
        #expect(store.bodies.read(flowID: new.id, side: .response)?.count == 1000)

        try store.enforceQuota(maxBytes: 1500)

        #expect(try store.flows().map(\.host) == ["new.test"])
        #expect(store.bodies.read(flowID: old.id, side: .response) == nil)
    }

    @Test func readPrefixReturnsAtMostMaxBytesAndTotalSize() throws {
        let store = try FlowStore(directory: dir)
        let id = UUID()
        let w = store.bodies.writer(flowID: id, side: .response)
        w.append([UInt8](repeating: 7, count: 3000))
        w.finish()
        FileBodySink.drain()

        let prefix = try #require(store.bodies.readPrefix(flowID: id, side: .response, maxBytes: 1024))
        #expect(prefix.data == Data(repeating: 7, count: 1024))
        #expect(prefix.totalSize == 3000)
        let whole = try #require(store.bodies.readPrefix(flowID: id, side: .response, maxBytes: 1 << 20))
        #expect(whole.data.count == 3000 && whole.totalSize == 3000)
        #expect(store.bodies.readPrefix(flowID: id, side: .request, maxBytes: 1024) == nil)
    }

    @Test func extensionStoreUsesOneReaderAndSmallCache() throws {
        let store = try FlowStore(directory: dir, readerCount: 1, smallCache: true)
        #expect(store.pool.configuration.maximumReaderCount == 1)
        #expect(try store.pool.read { db in try Int.fetchOne(db, sql: "PRAGMA cache_size") } == -512)
        #expect(try store.pool.write { db in try Int.fetchOne(db, sql: "PRAGMA cache_size") } == -512)
    }

    @Test func pinnedHostsAndSettingsPersist() throws {
        let store = try FlowStore(directory: dir)
        try store.setPinned("bank.test", true)
        try store.setSetting(Settings.excludedHosts, ["*.apple.com"])
        let reopened = try FlowStore(directory: dir)
        #expect(try reopened.pinnedHosts() == ["bank.test"])
        #expect(try reopened.setting(Settings.excludedHosts) == ["*.apple.com"])
        #expect(try reopened.setting(Settings.quotaBytes) == 2 * 1024 * 1024 * 1024)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

extension StorageTests {
    @Test func webSocketMessagesAreStoredWithTheirFlowAndDeletedWithIt() throws {
        let store = try FlowStore(directory: dir)
        var flow = sample("ws.test")
        flow.httpVersion = "HTTP/1.1"
        flow.graphQL = "query GetUser"
        let messages = (0..<3).map { i in
            WebSocketMessage(flowID: flow.id, seq: i, at: Date(), direction: i % 2 == 0 ? .sent : .received,
                             opcode: .text, length: 5, payload: Data("m\(i)".utf8), truncated: i == 2)
        }
        try store.upsert([flow], messages: messages)
        #expect(try store.flow(id: flow.id)?.graphQL == "query GetUser")
        #expect(try store.flow(id: flow.id)?.httpVersion == "HTTP/1.1")
        #expect(try store.flows({ var f = FlowFilter(); f.text = "GetUser"; return f }()).map(\.id) == [flow.id])
        let stored = try store.webSocketMessages(flowID: flow.id)
        #expect(stored.map(\.payload) == messages.map(\.payload))
        #expect(stored.map(\.direction) == [.sent, .received, .sent])
        #expect(stored.last?.truncated == true)
        try store.deleteAllFlows()
        #expect(try store.webSocketMessages(flowID: flow.id).isEmpty)
    }
}

extension StorageTests {
    @Test func apiCollectionsAreStoredNewestFirstAndDeleted() throws {
        let store = try FlowStore(directory: dir)
        let request = APIRequest(tag: "pets", name: "getPet", summary: nil, request: ComposedRequest(method: "GET", url: "https://p.test/pets/1"))
        let old = APICollection(title: "Old", version: nil, baseURL: "https://p.test", importedAt: Date(timeIntervalSince1970: 1), requests: [])
        let new = APICollection(title: "New", version: "2", baseURL: "https://p.test", importedAt: Date(timeIntervalSince1970: 2), requests: [request])
        try store.saveAPICollection(old)
        try store.saveAPICollection(new)
        #expect(try store.apiCollections().map(\.title) == ["New", "Old"])
        #expect(try store.apiCollections().first?.requests == [request])
        try store.deleteAPICollection(id: old.id)
        #expect(try store.apiCollections().map(\.title) == ["New"])
    }

    @Test func bodiesCanBeWrittenWhole() throws {
        let store = try FlowStore(directory: dir)
        let id = UUID()
        try store.bodies.write(Data("abc".utf8), flowID: id, side: .response)
        #expect(store.bodies.read(flowID: id, side: .response) == Data("abc".utf8))
    }
}
