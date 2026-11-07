import Foundation
import NIOCore
import ProxyModel

/// Reads WebSocket messages from copies of the bytes a relay forwards, one parser per direction.
/// Decoding never affects the relay: on a parse error that direction just stops decoding.
/// Confined to the relay's event loop.
final class WebSocketTap: @unchecked Sendable {
    static let maxMessages = 10_000

    private let flowID: UUID
    private let sink: FlowSink
    private let addNote: (String) -> Void
    private var parsers: [WebSocketDirection: WebSocketFrameParser] = [:]
    private var seq = 0
    private var full = false

    /// - Parameters:
    ///   - extensions: the `Sec-WebSocket-Extensions` header of the 101 response.
    ///   - addNote: appends a note to the flow.
    init(flowID: UUID, extensions: String?, sink: FlowSink, addNote: @escaping (String) -> Void) {
        self.flowID = flowID
        self.sink = sink
        self.addNote = addNote
        let params = Self.deflateParameters(extensions)
        parsers[.sent] = WebSocketFrameParser(perMessageDeflate: params != nil,
                                              noContextTakeover: params?.contains("client_no_context_takeover") ?? false)
        parsers[.received] = WebSocketFrameParser(perMessageDeflate: params != nil,
                                                  noContextTakeover: params?.contains("server_no_context_takeover") ?? false)
    }

    func feed(_ buffer: ByteBuffer, direction: WebSocketDirection) {
        guard var parser = parsers[direction] else { return }
        parsers[direction] = nil
        do {
            let messages = try parser.feed(buffer.readableBytesView)
            parsers[direction] = parser
            for m in messages { emit(m, direction: direction) }
        } catch {
            for m in error.messages { emit(m, direction: direction) }
            addNote("WebSocket: stopped decoding (\(error.reason))")
        }
    }

    private func emit(_ m: WebSocketFrameParser.ParsedMessage, direction: WebSocketDirection) {
        guard seq < Self.maxMessages else {
            if !full { full = true; addNote("WebSocket: message log full") }
            return
        }
        sink.webSocketMessage(WebSocketMessage(flowID: flowID, seq: seq, at: Date(), direction: direction, opcode: m.opcode,
                                               length: m.length, payload: m.payload, truncated: m.truncated))
        seq += 1
    }

    /// The parameters of the negotiated `permessage-deflate` extension, or nil when it is not in use.
    static func deflateParameters(_ header: String?) -> Set<String>? {
        guard let header else { return nil }
        for ext in header.split(separator: ",") {
            let parts = ext.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            if parts.first == "permessage-deflate" {
                return Set(parts.dropFirst().map { String($0.split(separator: "=").first ?? "") })
            }
        }
        return nil
    }
}
