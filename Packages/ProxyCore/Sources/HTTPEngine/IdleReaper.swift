import Foundation
import NIOCore

/// Closes decrypted client connections that sit idle. Each one holds two TLS sessions (about 140 KB of
/// swift-nio-ssl buffers) and the Network Extension may use only 50 MB, so idle keep-alive connections from
/// apps in the background would otherwise exhaust it. A connection with a request in flight, or upgraded to
/// WebSocket, is never closed.
public final class IdleReaper: @unchecked Sendable {
    public static let idleLimit: TimeInterval = 30
    public static let pressureIdleLimit: TimeInterval = 3

    private final class Entry {
        weak var channel: Channel?
        var lastActivity: TimeInterval
        var busy = 0
        init(channel: Channel, now: TimeInterval) { self.channel = channel; lastActivity = now }
    }

    private let lock = NSLock()
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var pressure = false
    private var timer: DispatchSourceTimer?
    private let clock: @Sendable () -> TimeInterval

    public init(clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    public var count: Int { lock.withLock { entries.count } }

    /// Under memory pressure idle connections go after `pressureIdleLimit` instead of `idleLimit`.
    public func setPressure(_ on: Bool) {
        lock.withLock { pressure = on }
        if on { sweep() }
    }

    public func start(queue: DispatchQueue = .global(qos: .utility), every interval: TimeInterval = 5) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in self?.sweep() }
        t.resume()
        timer = t
    }

    public func stop() { timer?.cancel(); timer = nil }

    /// Starts tracking a client connection; reads and writes on it count as activity.
    func track(_ channel: Channel) throws {
        let id = ObjectIdentifier(channel)
        let now = clock()
        lock.withLock { entries[id] = Entry(channel: channel, now: now) }
        try channel.pipeline.syncOperations.addHandler(ActivityHandler(reaper: self, id: id), position: .first)
        channel.closeFuture.whenComplete { [weak self] _ in
            self?.lock.withLock { _ = self?.entries.removeValue(forKey: id) }
        }
    }

    func touch(_ id: ObjectIdentifier) {
        let now = clock()
        lock.withLock { entries[id]?.lastActivity = now }
    }

    /// A request on `channel` (or on one of its HTTP/2 streams) started; the connection stays open until `end`.
    func begin(_ channel: Channel) {
        let id = ObjectIdentifier(channel)
        let now = clock()
        lock.withLock {
            entries[id]?.busy += 1
            entries[id]?.lastActivity = now
        }
    }

    func end(_ channel: Channel) {
        let id = ObjectIdentifier(channel)
        let now = clock()
        lock.withLock {
            guard let entry = entries[id] else { return }
            entry.busy = max(0, entry.busy - 1)
            entry.lastActivity = now
        }
    }

    /// Closes every idle connection past the current limit.
    public func sweep() {
        let now = clock()
        let idle: [Channel] = lock.withLock {
            let limit = pressure ? Self.pressureIdleLimit : Self.idleLimit
            return entries.values.compactMap { $0.busy == 0 && now - $0.lastActivity >= limit ? $0.channel : nil }
        }
        for channel in idle { channel.close(promise: nil) }
    }
}

/// First in a client pipeline: any read or write marks the connection active.
private final class ActivityHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    private weak var reaper: IdleReaper?
    private let id: ObjectIdentifier

    init(reaper: IdleReaper, id: ObjectIdentifier) { self.reaper = reaper; self.id = id }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        reaper?.touch(id)
        context.fireChannelRead(data)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        reaper?.touch(id)
        context.write(data, promise: promise)
    }
}
