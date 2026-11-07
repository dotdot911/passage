import Foundation

/// Cross-process "something changed" pings between app and extension (no payload).
public enum DarwinNotifier {
    public static func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(name as CFString), nil, nil, true)
    }
}

/// Observes one Darwin notification until deallocated. The handler runs on the main queue.
public final class DarwinObserver: @unchecked Sendable {
    private let name: String
    private let handler: @Sendable () -> Void

    public init(_ name: String, handler: @escaping @Sendable () -> Void) {
        self.name = name
        self.handler = handler
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), observer, { _, observer, _, _, _ in
            guard let observer else { return }
            let me = Unmanaged<DarwinObserver>.fromOpaque(observer).takeUnretainedValue()
            DispatchQueue.main.async { me.handler() }
        }, name as CFString, nil, .deliverImmediately)
    }

    deinit {
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                           Unmanaged.passUnretained(self).toOpaque(),
                                           CFNotificationName(name as CFString), nil)
    }
}

/// Coalesces bursts of posts to at most one per `interval` (the extension posts `db.changed`
/// after every recorder flush; the app does not need more than ~10 refreshes a second).
public final class ThrottledPoster: @unchecked Sendable {
    private let name: String
    private let interval: TimeInterval
    private let lock = NSLock()
    private var last = Date.distantPast
    private var scheduled = false
    private let post: @Sendable (String) -> Void

    public init(_ name: String, interval: TimeInterval = 0.1, post: @escaping @Sendable (String) -> Void = DarwinNotifier.post) {
        self.name = name
        self.interval = interval
        self.post = post
    }

    public func signal() {
        let delay: TimeInterval? = lock.withLock {
            if scheduled { return nil }
            let wait = max(0, interval - Date().timeIntervalSince(last))
            scheduled = true
            return wait
        }
        guard let delay else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            lock.withLock { scheduled = false; last = Date() }
            post(name)
        }
    }
}
