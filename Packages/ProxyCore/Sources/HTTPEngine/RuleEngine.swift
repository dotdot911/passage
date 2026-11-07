import Foundation
import ProxyModel
import Rules

/// The rules in force for one tunnel session. The rule set can be replaced while traffic flows.
public final class RuleEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var set: RuleSet
    /// Holds Map Local bodies, `<id>.body`.
    public let rulesDirectory: URL
    public let breakpoints: BreakpointCenter
    /// Runs Scripting rules; nil skips them.
    public let scripts: ScriptHost?

    public init(rules: RuleSet = .empty, rulesDirectory: URL, breakpoints: BreakpointCenter, scripts: ScriptHost? = nil) {
        self.set = rules
        self.rulesDirectory = rulesDirectory
        self.breakpoints = breakpoints
        self.scripts = scripts
    }

    public var current: RuleSet { lock.withLock { set } }
    public func update(_ rules: RuleSet) { lock.withLock { set = rules } }

    func mapLocalBody(_ ruleID: UUID) -> Data? {
        try? Data(contentsOf: rulesDirectory.appendingPathComponent("\(ruleID.uuidString).body"))
    }
}

/// Requests and responses paused at a breakpoint, waiting for the app.
public final class BreakpointCenter: @unchecked Sendable {
    public static let maxBodyBytes = 10 * 1024 * 1024

    private let lock = NSLock()
    private var waiting: [UUID: (item: BreakpointItem, resume: @Sendable (BreakpointDecision?) -> Void)] = [:]
    public let directory: URL
    private let maxPaused: Int
    private let timeout: TimeInterval
    private let onPause: @Sendable (BreakpointItem) -> Void
    private let onDrop: @Sendable (UUID) -> Void
    private let queue = DispatchQueue(label: "passage.breakpoints")

    /// - Parameters:
    ///   - directory: where held bodies are written (`<id>.body`); the app edits them in place.
    ///   - onPause: tells the app (event + notification).
    ///   - onDrop: tells the app an item went away because its client disconnected.
    public init(directory: URL, maxPaused: Int = 5, timeout: TimeInterval = 300,
                onPause: @escaping @Sendable (BreakpointItem) -> Void = { _ in },
                onDrop: @escaping @Sendable (UUID) -> Void = { _ in }) {
        self.directory = directory
        self.maxPaused = maxPaused
        self.timeout = timeout
        self.onPause = onPause
        self.onDrop = onDrop
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func bodyURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).body") }

    /// Holds `item` until the app answers or the timeout passes.
    /// - Parameter resume: called once, from any thread, with the decision or nil on timeout/cancel.
    /// - Returns: false when too many items are already paused (the caller continues unchanged).
    func pause(_ item: BreakpointItem, body: Data, resume: @escaping @Sendable (BreakpointDecision?) -> Void) -> Bool {
        let accepted: Bool = lock.withLock {
            guard waiting.count < maxPaused else { return false }
            waiting[item.id] = (item, resume)
            return true
        }
        guard accepted else { return false }
        try? body.write(to: bodyURL(item.id))
        onPause(item)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(item.id, nil) }
        return true
    }

    /// The app's answer. Returns false if the item is no longer waiting.
    @discardableResult
    public func resolve(id: UUID, decision: BreakpointDecision) -> Bool { finish(id, decision) }

    public func pending() -> [BreakpointItem] {
        lock.withLock { waiting.values.map(\.item).sorted { $0.createdAt < $1.createdAt } }
    }

    /// Forgets an item whose client has gone, so the app stops offering to resume it.
    func drop(_ id: UUID) {
        guard finish(id, nil) else { return }
        try? FileManager.default.removeItem(at: bodyURL(id))
        onDrop(id)
    }

    /// Lets everything through unchanged (tunnel stopping).
    public func cancelAll() {
        for id in lock.withLock({ Array(waiting.keys) }) { finish(id, nil) }
    }

    /// The held body as it is now (the app may have edited it); the file is removed.
    func takeBody(_ id: UUID) -> Data {
        defer { try? FileManager.default.removeItem(at: bodyURL(id)) }
        return (try? Data(contentsOf: bodyURL(id))) ?? Data()
    }

    @discardableResult
    private func finish(_ id: UUID, _ decision: BreakpointDecision?) -> Bool {
        guard let entry = lock.withLock({ waiting.removeValue(forKey: id) }) else { return false }
        entry.resume(decision)
        return true
    }
}
