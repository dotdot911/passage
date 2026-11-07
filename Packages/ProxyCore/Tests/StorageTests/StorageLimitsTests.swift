import Foundation
import GRDB
import ProxyModel
@testable import Storage
import Testing

@Suite struct StorageLimitsTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ps-\(UUID().uuidString)")

    func flow(_ host: String, ago seconds: TimeInterval = 0, state: FlowState = .completed) -> FlowRecord {
        var f = FlowRecord(startedAt: Date().addingTimeInterval(-seconds), kind: .https, host: host, ip: "1.2.3.4", port: 443)
        f.state = state
        return f
    }

    func writeBody(_ store: FlowStore, _ id: UUID, bytes: Int) {
        let w = store.bodies.writer(flowID: id, side: .response)
        w.append([UInt8](repeating: 1, count: bytes))
        w.finish()
        FileBodySink.drain()
    }

    func age(_ store: FlowStore, _ id: UUID, by seconds: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-seconds)],
                                              ofItemAtPath: store.bodies.url(flowID: id, side: .response).path)
    }

    @Test func bodyStopsAtTheLimitAndKeepsThePrefix() throws {
        let bodies = BodyStore(directory: dir, maxBodyBytes: 1000)
        let id = UUID()
        let w = bodies.writer(flowID: id, side: .request)
        w.append([UInt8](repeating: 1, count: 600))
        w.append([UInt8](repeating: 2, count: 600))
        w.append([UInt8](repeating: 3, count: 10))
        w.finish()
        FileBodySink.drain()
        #expect(bodies.read(flowID: id, side: .request) == Data(repeating: 1, count: 600) + Data(repeating: 2, count: 400))
    }

    @Test func oldOrphanBodiesGoBeforeAnyFlow() throws {
        let store = try FlowStore(directory: dir)
        let kept = flow("kept.test", ago: 100)
        try store.upsert([kept])
        writeBody(store, kept.id, bytes: 500)
        let orphan = UUID()
        writeBody(store, orphan, bytes: 2000)
        try age(store, orphan, by: FlowStore.orphanGracePeriod + 60)

        #expect(try store.enforceQuota(maxBytes: 1000) == 0)
        #expect(try store.flows().map(\.host) == ["kept.test"])
        #expect(store.bodies.read(flowID: orphan, side: .response) == nil)
    }

    @Test func recentOrphanBodiesAreKept() throws {
        let store = try FlowStore(directory: dir)
        let pendingRow = UUID()
        writeBody(store, pendingRow, bytes: 2000)
        try store.enforceQuota(maxBytes: 1000)
        #expect(store.bodies.read(flowID: pendingRow, side: .response)?.count == 2000)
    }

    @Test func activeFlowsSurviveTheQuota() throws {
        let store = try FlowStore(directory: dir)
        let download = flow("big.test", ago: 200, state: .active)
        let done = flow("done.test", ago: 100)
        try store.upsert([download, done])
        writeBody(store, download.id, bytes: 5000)
        writeBody(store, done.id, bytes: 100)

        #expect(try store.enforceQuota(maxBytes: 1000) == 1)
        #expect(try store.flows().map(\.host) == ["big.test"])
    }

    @Test func recorderRetriesAFailedWrite() throws {
        let store = try FlowStore(directory: dir)
        try store.pool.write { db in
            try db.execute(sql: "CREATE TEMP TRIGGER fail BEFORE INSERT ON flow BEGIN SELECT RAISE(FAIL, 'disk full'); END")
        }
        let recorder = FlowRecorder(store: store)
        recorder.record(flow("retry.test"))
        recorder.waitForPendingFlush()
        #expect(try store.flows().isEmpty)

        try store.pool.write { db in try db.execute(sql: "DROP TRIGGER temp.fail") }
        recorder.waitForPendingFlush()
        #expect(try store.flows().map(\.host) == ["retry.test"])
    }
}
