import Foundation

/// Extension side of the long-poll channel. `wait` holds the completion handler of an
/// `awaitEvents` message until an event is pushed or the poll times out.
public final class EventQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [TunnelEvent] = []
    private var waiter: (id: UUID, reply: @Sendable ([TunnelEvent]) -> Void)?
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "passage.events")

    public init(timeout: TimeInterval = IPCConstants.longPollSeconds) { self.timeout = timeout }

    /// Script log lines kept while the app is not polling; older ones are dropped first.
    public static let maxPendingLogs = 200

    public func push(_ event: TunnelEvent) {
        let toWake: (@Sendable ([TunnelEvent]) -> Void, [TunnelEvent])? = lock.withLock {
            pending.append(event)
            if case .scriptLog = event, pending.count > Self.maxPendingLogs,
               let oldest = pending.firstIndex(where: { if case .scriptLog = $0 { true } else { false } }) {
                pending.remove(at: oldest)
            }
            guard let w = waiter else { return nil }
            waiter = nil
            defer { pending.removeAll() }
            return (w.reply, pending)
        }
        if let (reply, events) = toWake { reply(events) }
    }

    /// Answers immediately if events are queued; otherwise parks `reply`. A newer wait replaces
    /// an older one (which is answered with no events).
    public func wait(_ reply: @escaping @Sendable ([TunnelEvent]) -> Void) {
        let id = UUID()
        let action: (immediate: [TunnelEvent]?, replaced: (@Sendable ([TunnelEvent]) -> Void)?) = lock.withLock {
            if !pending.isEmpty {
                defer { pending.removeAll() }
                return (pending, nil)
            }
            let old = waiter?.reply
            waiter = (id, reply)
            return (nil, old)
        }
        action.replaced?([])
        if let events = action.immediate { reply(events); return }
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            let expired: (@Sendable ([TunnelEvent]) -> Void)? = lock.withLock {
                guard waiter?.id == id else { return nil }
                defer { waiter = nil }
                return waiter?.reply
            }
            expired?([])
        }
    }
}
