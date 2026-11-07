import Foundation

/// Maps IP addresses to the hostname the client resolved them from (learned from DNS answers),
/// so flows without SNI/Host still get a readable name.
public final class HostCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (host: String, expires: Date)] = [:]
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) { self.now = now }

    /// TTL is clamped to 60 s ... 1 h.
    public func remember(ip: String, host: String, ttl: UInt32) {
        let seconds = min(max(TimeInterval(ttl), 60), 3600)
        lock.withLock {
            entries[ip] = (host, now().addingTimeInterval(seconds))
            if entries.count > 4096 { evictExpired() }
        }
    }

    public func host(for ip: String) -> String? {
        lock.withLock {
            guard let e = entries[ip] else { return nil }
            if e.expires < now() { entries[ip] = nil; return nil }
            return e.host
        }
    }

    private func evictExpired() {
        let t = now()
        entries = entries.filter { $0.value.expires >= t }
    }
}
