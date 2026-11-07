import Foundation

public enum WebSocketDirection: String, Codable, Sendable { case sent, received }

/// The kind of a whole WebSocket message; continuation frames are merged into the message they continue.
public enum WebSocketOpcode: String, Codable, Sendable { case text, binary, close, ping, pong }

/// One WebSocket message of a flow, as recorded by the engine.
public struct WebSocketMessage: Codable, Hashable, Sendable {
    public var flowID: UUID
    /// Position in the flow, counting both directions.
    public var seq: Int
    public var at: Date
    public var direction: WebSocketDirection
    public var opcode: WebSocketOpcode
    /// Full payload length (after permessage-deflate inflation), even when `payload` is cut.
    public var length: Int
    /// The payload, cut at the recording limit.
    public var payload: Data
    public var truncated: Bool

    public init(flowID: UUID, seq: Int, at: Date, direction: WebSocketDirection, opcode: WebSocketOpcode,
                length: Int, payload: Data, truncated: Bool) {
        self.flowID = flowID
        self.seq = seq
        self.at = at
        self.direction = direction
        self.opcode = opcode
        self.length = length
        self.payload = payload
        self.truncated = truncated
    }
}
