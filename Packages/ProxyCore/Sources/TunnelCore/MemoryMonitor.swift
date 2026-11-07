import Foundation

/// Polls available memory once a second and toggles low-memory mode with hysteresis:
/// enter below 16 MB, leave above 24 MB.
public final class MemoryMonitor: @unchecked Sendable {
    public static let enterBelow = 16 * 1024 * 1024
    public static let leaveAbove = 24 * 1024 * 1024

    private let probe: @Sendable () -> Int?
    private let onChange: @Sendable (Bool) -> Void
    private let lock = NSLock()
    private var low = false
    private var timer: DispatchSourceTimer?

    /// - Parameter probe: bytes still available to the process, or nil if unknown (macOS tests).
    public init(probe: @escaping @Sendable () -> Int? = MemoryMonitor.systemAvailableBytes,
                onChange: @escaping @Sendable (Bool) -> Void) {
        self.probe = probe
        self.onChange = onChange
    }

    public var isLow: Bool { lock.withLock { low } }

    /// Re-reads available memory, so a burst of new connections sees the drop before the next poll.
    public var isLowNow: Bool {
        guard let available = probe() else { return isLow }
        return available < Self.enterBelow || isLow
    }

    public func start(queue: DispatchQueue = .global(qos: .utility)) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.check() }
        t.resume()
        timer = t
    }

    public func stop() { timer?.cancel(); timer = nil }

    /// One evaluation step (exposed for tests).
    public func check() {
        guard let available = probe() else { return }
        let changed: Bool? = lock.withLock {
            if !low && available < Self.enterBelow { low = true; return true }
            if low && available > Self.leaveAbove { low = false; return false }
            return nil
        }
        if let changed { onChange(changed) }
    }

    public static let systemAvailableBytes: @Sendable () -> Int? = {
        #if os(iOS)
        return Int(os_proc_available_memory())
        #else
        return nil
        #endif
    }
}
