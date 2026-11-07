import Foundation
@testable import IPC
import ProxyModel
import Testing

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
}

@Suite struct IPCTests {
    @Test func messagesRoundTrip() throws {
        let send = AppMessage.send(flowID: UUID(), request: ComposedRequest(method: "POST", url: "https://a.test/",
                                                                          headers: [HeaderField(name: "A", value: "1")]))
        for m in [AppMessage.reloadSettings, .clearSession, .stats, .awaitEvents, send, .resetScriptState] {
            #expect(try IPCCodec.decode(AppMessage.self, from: IPCCodec.encode(m)) == m)
        }
        let log = ScriptLog(level: .warn, message: "hi", scriptName: "s", date: Date(timeIntervalSince1970: 5))
        let reply = ProviderReply.events([.hostPinned("bank.test"), .lowMemory(true), .scriptLog(log)])
        #expect(try IPCCodec.decode(ProviderReply.self, from: IPCCodec.encode(reply)) == reply)
    }

    @Test func scriptLogsAreCapped() {
        let q = EventQueue(timeout: 5)
        q.push(.lowMemory(true))
        for i in 0..<250 { q.push(.scriptLog(ScriptLog(level: .log, message: "\(i)", scriptName: "s"))) }
        let got = Box<[TunnelEvent]?>(nil)
        q.wait { got.value = $0 }
        #expect(got.value?.count == EventQueue.maxPendingLogs)
        #expect(got.value?.first == .lowMemory(true))
        if case .scriptLog(let last)? = got.value?.last { #expect(last.message == "249") } else { Issue.record("no log") }
    }

    @Test func waitReturnsQueuedEventsImmediately() {
        let q = EventQueue(timeout: 5)
        q.push(.lowMemory(true))
        let got = Box<[TunnelEvent]?>(nil)
        q.wait { got.value = $0 }
        #expect(got.value == [.lowMemory(true)])
    }

    @Test func parkedWaitIsAnsweredByPushOrTimeout() async {
        let q = EventQueue(timeout: 0.1)
        let first = Box<[TunnelEvent]?>(nil)
        q.wait { first.value = $0 }
        #expect(first.value == nil)
        q.push(.hostPinned("a.test"))
        #expect(first.value == [.hostPinned("a.test")])

        let second = Box<[TunnelEvent]?>(nil)
        q.wait { second.value = $0 }
        try? await Task.sleep(for: .milliseconds(250))
        #expect(second.value == [])
    }

    @Test func throttledPosterCoalescesBursts() async {
        let posts = Box(0)
        let poster = ThrottledPoster("x", interval: 0.1) { _ in posts.value += 1 }
        for _ in 0..<50 { poster.signal() }
        try? await Task.sleep(for: .milliseconds(150))
        // Leading post plus at most one trailing post per interval.
        #expect((1...2).contains(posts.value))
    }
}
