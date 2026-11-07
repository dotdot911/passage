import Foundation
import HTTPEngine
import NIOCore
import NIOPosix
import ProxyModel

/// Collects everything the engine records.
public final class MemorySink: FlowSink, @unchecked Sendable {
    private let lock = NSLock()
    private var flows: [UUID: FlowRecord] = [:]
    private var bodies: [String: [UInt8]] = [:]

    public init() {}

    public func record(_ flow: FlowRecord) { lock.withLock { flows[flow.id] = flow } }
    public func bodySink(flowID: UUID, side: BodySide) -> BodySink? { Body(sink: self, key: "\(flowID)-\(side.rawValue)") }
    public func webSocketMessage(_ message: WebSocketMessage) { lock.withLock { messages.append(message) } }
    public var webSocketMessages: [WebSocketMessage] { lock.withLock { messages } }
    private var messages: [WebSocketMessage] = []

    /// Polls until `predicate` holds (the engine records asynchronously), up to 2 s.
    public func waitFor(_ predicate: @escaping ([FlowRecord]) -> Bool) async -> Bool {
        for _ in 0..<200 {
            if predicate(all) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate(all)
    }

    public var all: [FlowRecord] { lock.withLock { Array(flows.values) } }
    public func body(_ id: UUID, _ side: BodySide) -> String {
        lock.withLock { String(decoding: bodies["\(id)-\(side.rawValue)"] ?? [], as: UTF8.self) }
    }

    private struct Body: BodySink {
        let sink: MemorySink
        let key: String
        func append(_ bytes: [UInt8]) { sink.lock.withLock { sink.bodies[key, default: []] += bytes } }
        func finish() {}
    }
}

/// Sends every upstream connection to a fixed local address, regardless of destination.
public struct LocalConnector: UpstreamConnector {
    public let target: SocketAddress
    public init(target: SocketAddress) { self.target = target }
    public func connect(to destination: IPEndpoint, on loop: EventLoop,
                 initializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>) -> EventLoopFuture<Channel> {
        ClientBootstrap(group: loop)
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .channelInitializer(initializer)
            .connect(to: target)
    }
}
