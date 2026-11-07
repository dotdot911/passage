import Foundation
import ProxyModel

/// `FlowSink` used by the extension: coalesces record updates and writes them in one
/// transaction every 100 ms, so the network path never waits on SQLite.
public final class FlowRecorder: FlowSink, @unchecked Sendable {
    public static let flushInterval: DispatchTimeInterval = .milliseconds(100)
    /// After a failed write the batch waits this long before the next try.
    public static let retryInterval: DispatchTimeInterval = .seconds(1)
    /// Records kept for a retry while the database keeps failing; the oldest go first.
    public static let maxPending = 2000

    private let store: FlowStore
    private let queue = DispatchQueue(label: "passage.recorder")
    private let lock = NSLock()
    private var pending: [UUID: FlowRecord] = [:]
    private var pendingMessages: [WebSocketMessage] = []
    private var scheduled = false
    private let didFlush: @Sendable () -> Void

    /// - Parameter didFlush: called after each write (the extension posts `db.changed`).
    public init(store: FlowStore, didFlush: @escaping @Sendable () -> Void = {}) {
        self.store = store
        self.didFlush = didFlush
    }

    public func record(_ flow: FlowRecord) {
        enqueue { pending[flow.id] = flow }
    }

    public func webSocketMessage(_ message: WebSocketMessage) {
        enqueue { pendingMessages.append(message) }
    }

    private func enqueue(_ add: () -> Void) {
        let schedule: Bool = lock.withLock {
            add()
            if scheduled { return false }
            scheduled = true
            return true
        }
        if schedule { queue.asyncAfter(deadline: .now() + Self.flushInterval) { [self] in flush() } }
    }

    public func bodySink(flowID: UUID, side: BodySide) -> BodySink? {
        store.bodies.writer(flowID: flowID, side: side)
    }

    /// Writes everything pending now. Also used by tests and on tunnel stop.
    public func flush() {
        let (batch, messages): ([FlowRecord], [WebSocketMessage]) = lock.withLock {
            scheduled = false
            defer { pending.removeAll(); pendingMessages.removeAll() }
            return (Array(pending.values), pendingMessages)
        }
        guard !batch.isEmpty || !messages.isEmpty else { return }
        do {
            try store.upsert(batch, messages: messages)
            didFlush()
        } catch {
            NSLog("Passage: failed to write \(batch.count) flows, will retry: \(error)")
            requeue(batch, messages: messages)
        }
    }

    /// Puts a failed batch back without overwriting newer versions recorded meanwhile.
    private func requeue(_ batch: [FlowRecord], messages: [WebSocketMessage]) {
        let schedule: Bool = lock.withLock {
            for f in batch where pending[f.id] == nil { pending[f.id] = f }
            if pending.count > Self.maxPending {
                let drop = pending.values.sorted { $0.startedAt < $1.startedAt }.prefix(pending.count - Self.maxPending)
                for f in drop { pending[f.id] = nil }
            }
            pendingMessages = Array((messages + pendingMessages).suffix(Self.maxPending))
            if scheduled { return false }
            scheduled = true
            return true
        }
        if schedule { queue.asyncAfter(deadline: .now() + Self.retryInterval) { [self] in flush() } }
    }

    /// Blocks until queued flushes ran (tests).
    public func waitForPendingFlush() {
        queue.sync {}
        flush()
    }
}
