import Foundation
import ProxyModel

/// Sent by the app through `NETunnelProviderSession.sendProviderMessage`.
public enum AppMessage: Codable, Equatable, Sendable {
    /// Re-read settings (excluded hosts, quota) from the shared database.
    case reloadSettings
    case clearSession
    case stats
    /// Long-poll: the extension answers when events exist, or after `IPCConstants.longPollSeconds`.
    case awaitEvents
    /// Sends a composed request; its body (if any) is already in `bodies/<flowID>.req` and `request.body` is nil.
    case send(flowID: UUID, request: ComposedRequest)
    /// Answers a paused breakpoint. The body has already been written back to its file.
    case resumeBreakpoint(id: UUID, decision: BreakpointDecision)
    /// Lists breakpoints still waiting for an answer.
    case pendingBreakpoints
    /// Clears the scripts' `$shared` object.
    case resetScriptState
}

public enum ProviderReply: Codable, Equatable, Sendable {
    case ok
    case stats(TunnelStats)
    case events([TunnelEvent])
    case breakpoints([BreakpointItem])
    case error(String)
}

public struct TunnelStats: Codable, Equatable, Sendable {
    public var startedAt: Date
    public var activeConnections: Int
    public var lowMemory: Bool
    /// True once a client completed a TLS handshake with one of our leaf certificates.
    public var caTrusted: Bool
    public init(startedAt: Date, activeConnections: Int, lowMemory: Bool, caTrusted: Bool) {
        self.startedAt = startedAt; self.activeConnections = activeConnections
        self.lowMemory = lowMemory; self.caTrusted = caTrusted
    }
}

/// Pushed from the extension to the app.
public enum TunnelEvent: Codable, Equatable, Sendable {
    case lowMemory(Bool)
    case hostPinned(String)
    case breakpoint(BreakpointItem)
    /// A paused message whose client disconnected; it can no longer continue.
    case breakpointDropped(UUID)
    case scriptLog(ScriptLog)
}

public enum IPCConstants {
    public static let appGroup = "group.com.passage.io"
    public static let longPollSeconds: TimeInterval = 25
    /// Darwin notification names (no payload).
    public static let dbChanged = "com.passage.io.db.changed"
    public static let settingsChanged = "com.passage.io.settings.changed"
}

public enum IPCCodec {
    public static func encode<T: Encodable>(_ value: T) -> Data {
        // Encoding these plain enums cannot fail.
        try! JSONEncoder().encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
