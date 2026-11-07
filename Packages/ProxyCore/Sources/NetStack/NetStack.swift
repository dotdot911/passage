import CLwIP
@_exported import ProxyModel
import Foundation

public protocol NetStackDelegate: AnyObject {
    /// An IP packet that must be written to the tunnel (`packetFlow.writePackets`).
    func netStack(_ stack: NetStack, emit packet: Data)
    /// A client opened a TCP connection. Called on `stack.queue`.
    func netStack(_ stack: NetStack, didAccept connection: TCPConnection)
}

/// Wraps the vendored lwIP. lwIP has global state, so there is exactly one instance.
/// Every call into the stack must happen on `queue`.
public final class NetStack: @unchecked Sendable {
    public static let shared = NetStack()

    public let queue = DispatchQueue(label: "passage.netstack")
    public weak var delegate: NetStackDelegate?

    private var started = false
    private var timer: DispatchSourceTimer?
    /// Live connections keyed by lwIP pcb. Only touch on `queue`.
    public internal(set) var connections: [UnsafeMutableRawPointer: TCPConnection] = [:]

    private init() {}

    /// Initializes lwIP and starts its timers. Idempotent.
    public func start() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !started else { return }
        started = true
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        ps_stack_init(ps_callbacks(
            ctx: ctx,
            output: { ctx, bytes, len in
                let stack = Unmanaged<NetStack>.fromOpaque(ctx!).takeUnretainedValue()
                stack.delegate?.netStack(stack, emit: Data(bytes: bytes!, count: len))
            },
            accept: { ctx, pcb, isV6, src, srcPort, dst, dstPort in
                let stack = Unmanaged<NetStack>.fromOpaque(ctx!).takeUnretainedValue()
                let n = isV6 != 0 ? 16 : 4
                let conn = TCPConnection(
                    stack: stack, pcb: pcb!,
                    source: IPEndpoint(address: Array(UnsafeBufferPointer(start: src, count: n)), port: srcPort),
                    destination: IPEndpoint(address: Array(UnsafeBufferPointer(start: dst, count: n)), port: dstPort))
                stack.connections[pcb!] = conn
                stack.delegate?.netStack(stack, didAccept: conn)
            },
            recv: { ctx, pcb, bytes, len in
                let stack = Unmanaged<NetStack>.fromOpaque(ctx!).takeUnretainedValue()
                guard let conn = stack.connections[pcb!] else { return }
                if len == 0 { conn.handleRemoteFIN() } else { conn.handleData(Data(bytes: bytes!, count: len)) }
            },
            sent: { ctx, pcb, _ in
                let stack = Unmanaged<NetStack>.fromOpaque(ctx!).takeUnretainedValue()
                stack.connections[pcb!]?.handleSent()
            },
            error: { ctx, pcb, err in
                let stack = Unmanaged<NetStack>.fromOpaque(ctx!).takeUnretainedValue()
                guard let pcb, let conn = stack.connections.removeValue(forKey: pcb) else { return }
                conn.handleReset(code: Int(err))
            }
        ))
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        t.setEventHandler { ps_stack_check_timeouts() }
        t.resume()
        timer = t
    }

    /// Feeds one IP packet that carries TCP. Must be called on `queue`.
    @discardableResult
    public func input(_ packet: Data) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return packet.withUnsafeBytes { raw in
            ps_stack_input(raw.bindMemory(to: UInt8.self).baseAddress, raw.count) == 0
        }
    }

    func forget(_ pcb: UnsafeMutableRawPointer) {
        connections.removeValue(forKey: pcb)
    }
}
