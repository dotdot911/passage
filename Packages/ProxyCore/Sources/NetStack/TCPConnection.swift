import CLwIP
import Foundation

/// One client TCP connection terminated by lwIP. All members must be used on `NetStack.queue`.
///
/// Backpressure: received bytes are only acknowledged to the client when the consumer
/// calls `consumed(_:)`, so a slow upstream shrinks the client's TCP window instead of RAM.
public final class TCPConnection: @unchecked Sendable {
    public let source: IPEndpoint
    public let destination: IPEndpoint

    /// Bytes from the client. Call `consumed(_:)` once they are forwarded.
    /// Data that arrived before this was set (same queue turn as accept) is delivered on assignment.
    public var onData: ((Data) -> Void)? {
        didSet {
            guard let onData, !earlyData.isEmpty else { return }
            let chunks = earlyData
            earlyData.removeAll()
            chunks.forEach(onData)
        }
    }
    /// The client half-closed (FIN). Fires on assignment if the FIN already arrived.
    public var onRemoteClose: (() -> Void)? {
        didSet { if remoteClosed, let onRemoteClose { onRemoteClose() } }
    }
    /// The connection is gone (RST or abort). The object is unusable afterwards.
    public var onReset: ((Int) -> Void)?
    /// Pending outbound bytes were handed to lwIP; `pendingWriteBytes` shrank.
    public var onWritable: (() -> Void)?

    private unowned let stack: NetStack
    private var pcb: UnsafeMutableRawPointer?
    private var outbound = Data()
    private var wantsShutdownWrite = false
    private var earlyData: [Data] = []
    private var remoteClosed = false

    init(stack: NetStack, pcb: UnsafeMutableRawPointer, source: IPEndpoint, destination: IPEndpoint) {
        self.stack = stack
        self.pcb = pcb
        self.source = source
        self.destination = destination
    }

    public var isOpen: Bool { pcb != nil }
    /// Bytes accepted by `write` but not yet handed to lwIP.
    public var pendingWriteBytes: Int { outbound.count }

    /// Queues bytes for the client. Never blocks; check `pendingWriteBytes` for backpressure.
    public func write(_ data: Data) {
        guard pcb != nil, !data.isEmpty else { return }
        outbound.append(data)
        flush()
    }

    /// Acknowledges `count` bytes previously delivered via `onData`.
    public func consumed(_ count: Int) {
        guard let pcb, count > 0 else { return }
        ps_tcp_recved(pcb, count)
    }

    /// Sends FIN after all queued bytes are written.
    public func shutdownWrite() {
        wantsShutdownWrite = true
        flush()
    }

    public func close() {
        guard let pcb else { return }
        self.pcb = nil
        stack.forget(pcb)
        ps_tcp_close(pcb)
        clearCallbacks()
    }

    /// lwIP's ERR_ABRT, passed to `onReset` when an abort notifies the consumer.
    public static let abortedCode = -13

    /// Sends RST and drops the connection.
    /// - Parameter notify: when true, `onReset` fires first so the consumer (e.g. the socket
    ///   bridge) tears down its side; leave false when the consumer itself is aborting.
    public func abort(notify: Bool = false) {
        guard let pcb else { return }
        self.pcb = nil
        outbound.removeAll()
        stack.forget(pcb)
        ps_tcp_abort(pcb)
        if notify { onReset?(Self.abortedCode) }
        clearCallbacks()
    }

    // MARK: lwIP callbacks (via NetStack)

    func handleData(_ data: Data) {
        if let onData { onData(data) } else { earlyData.append(data) }
    }
    func handleRemoteFIN() {
        remoteClosed = true
        onRemoteClose?()
    }
    func handleSent() {
        flush()
        onWritable?()
    }
    func handleReset(code: Int) {
        pcb = nil
        outbound.removeAll()
        onReset?(code)
        clearCallbacks()
    }

    /// Drops consumer closures so a finished connection cannot be kept alive by capture cycles.
    private func clearCallbacks() {
        onData = nil
        onRemoteClose = nil
        onReset = nil
        onWritable = nil
    }

    private func flush() {
        guard let pcb else { return }
        while !outbound.isEmpty {
            let n = outbound.withUnsafeBytes { raw in
                ps_tcp_write(pcb, raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
            }
            if n == 0 { break }
            outbound.removeFirst(n)
        }
        if outbound.isEmpty && wantsShutdownWrite {
            wantsShutdownWrite = false
            ps_tcp_shutdown_write(pcb)
        }
    }
}
