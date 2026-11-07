import Foundation

public enum FlowKind: String, Codable, Sendable { case http, https, raw, dns }
public enum FlowState: String, Codable, Sendable { case active, completed, failed, paused }

/// One header line. Order and duplicates are preserved.
public struct HeaderField: Codable, Hashable, Sendable {
    public var name: String
    public var value: String
    public init(name: String, value: String) { self.name = name; self.value = value }
}

/// Everything the UI shows about one exchange (or one raw connection).
public struct FlowRecord: Codable, Hashable, Sendable, Identifiable {
    /// Starts `error` when the server, not the client, failed the TLS handshake.
    public static let upstreamTLSPrefix = "Upstream TLS failed"
    /// Starts `error` when the client refused the Passage certificate with a TLS alert.
    public static let clientRejectedPrefix = "Client rejected the Passage certificate"

    public var id: UUID
    public var startedAt: Date
    public var endedAt: Date?
    public var kind: FlowKind
    public var state: FlowState
    public var host: String
    public var ip: String
    public var port: Int
    public var method: String?
    public var url: String?
    public var statusCode: Int?
    public var requestHeaders: [HeaderField]
    public var responseHeaders: [HeaderField]
    public var requestBytes: Int
    public var responseBytes: Int
    /// Milliseconds from start until the upstream TCP (+TLS) connection was ready.
    public var connectMs: Double?
    /// Milliseconds from start until the response head arrived.
    public var ttfbMs: Double?
    public var error: String?
    public var note: String?
    /// "HTTP/1.1" or "HTTP/2" for decrypted or plain HTTP exchanges; nil for tunnels, raw and DNS.
    public var httpVersion: String?
    /// The GraphQL operation, e.g. "query GetUser", when the request is GraphQL.
    public var graphQL: String?
    /// The signing identifier of the app that opened the connection, when the platform reports it (macOS).
    public var client: String?

    public init(id: UUID = UUID(), startedAt: Date = Date(), kind: FlowKind, host: String, ip: String, port: Int) {
        self.id = id
        self.startedAt = startedAt
        self.kind = kind
        self.state = .active
        self.host = host
        self.ip = ip
        self.port = port
        self.requestHeaders = []
        self.responseHeaders = []
        self.requestBytes = 0
        self.responseBytes = 0
    }
}

public enum BodySide: String, Codable, Sendable { case request = "req", response = "res" }

/// Receives a body as it streams. Implementations must not block the caller.
public protocol BodySink: Sendable {
    func append(_ bytes: [UInt8])
    func finish()
}

/// Where the engine reports traffic. Implemented by Storage's FlowRecorder.
public protocol FlowSink: Sendable {
    /// Inserts or replaces the record with the same id.
    func record(_ flow: FlowRecord)
    /// A writer for the body, or nil when bodies are not being recorded.
    func bodySink(flowID: UUID, side: BodySide) -> BodySink?
    /// A WebSocket message read from an upgraded flow, recorded after the flow itself.
    func webSocketMessage(_ message: WebSocketMessage)
}

extension FlowSink {
    public func webSocketMessage(_ message: WebSocketMessage) {}
}
