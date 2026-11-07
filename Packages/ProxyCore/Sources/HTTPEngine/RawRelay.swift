import Foundation
import NIOCore
import ProxyModel

/// Pipes a client connection to its original destination without looking inside.
/// Used for non-HTTP traffic and for TLS that is not decrypted (recorded as `.https`).
enum RawRelay {
    /// - Parameter recorded: false relays without writing a flow (hosts outside the Allow List).
    static func start(downstream: Channel, destination: IPEndpoint, host: String, note: String?,
                      sniff: SniffHandler, config: EngineConfig, kind: FlowKind = .raw, recorded: Bool = true) {
        let sink: FlowSink = recorded ? config.sink : NullSink()
        var record = FlowRecord(kind: kind, host: host, ip: destination.host, port: Int(destination.port))
        record.note = note
        if kind == .https {
            // Shown like a proxy CONNECT tunnel: only the host is known.
            record.method = "CONNECT"
            record.url = "https://\(host)" + (destination.port == 443 ? "" : ":\(destination.port)")
            record.requestHeaders = [HeaderField(name: "Host", value: host)]
        }
        let started = Date()
        sink.record(record)
        let (down, up) = GlueHandler.matchedPair()
        let box = RecordBox(record)
        down.onBytes = { box.value.requestBytes += $0 }
        up.onBytes = { box.value.responseBytes += $0 }
        down.onClose = {
            box.value.state = .completed
            box.value.endedAt = Date()
            sink.record(box.value)
        }
        config.connector.connect(to: destination, on: downstream.eventLoop) { ch in
            ch.eventLoop.makeCompletedFuture { try ch.pipeline.syncOperations.addHandler(up) }
        }.whenComplete { result in
            switch result {
            case .success(let upstream):
                box.value.connectMs = Date().timeIntervalSince(started) * 1000
                if box.value.kind == .https { box.value.statusCode = 200 }
                do {
                    try downstream.pipeline.syncOperations.addHandler(down)
                    sniff.release()
                } catch {
                    // Client went away while we were connecting.
                    upstream.close(promise: nil)
                    box.value.state = .failed
                    box.value.error = "Client closed during connect"
                    box.value.endedAt = Date()
                    sink.record(box.value)
                    downstream.close(promise: nil)
                }
            case .failure(let error):
                box.value.state = .failed
                box.value.error = "Connect failed: \(error)"
                box.value.endedAt = Date()
                sink.record(box.value)
                downstream.close(promise: nil)
            }
        }
    }
}

/// Mutable record shared between the callbacks of one flow (all on one event loop).
final class RecordBox: @unchecked Sendable {
    var value: FlowRecord
    init(_ value: FlowRecord) { self.value = value }
}

/// Records nothing.
struct NullSink: FlowSink {
    func record(_ flow: FlowRecord) {}
    func bodySink(flowID: UUID, side: BodySide) -> BodySink? { nil }
}
