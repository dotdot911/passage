import CertKit
import Foundation
import IPC
import Network
import NetworkExtension
import HTTPEngine
import ProxyModel
import Rules
import Scripting
import Storage
import TunnelCore
import UserNotifications

/// The Network Extension entry point. Owns the engine and answers app messages.
final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    /// The device's address inside the tunnel. 198.18.0.1 is reserved for the internal site.
    static let interfaceIPv4 = "198.18.0.2"
    static let interfaceIPv6 = "fd00:5050::2"

    private var engine: TunnelEngine?
    private var store: FlowStore?
    private var recorder: FlowRecorder?
    private var rules: RuleEngine?
    private var scripts: ScriptRunner?
    private let events = EventQueue()
    private var startedAt = Date()
    private var quotaTimer: DispatchSourceTimer?
    private let pathMonitor = NWPathMonitor()
    private var lastInterface: String?
    /// Whether the physical network has IPv6; the tunnel claims IPv6 only when it does, otherwise
    /// clients would pick AAAA addresses that the extension cannot reach ("No route to host").
    private var ipv6Routed = false
    private let stats = PacketStats()
    private var statsTimer: DispatchSourceTimer?

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        Self.raiseFileLimit()
        do {
            // One reader and a 512 KB page cache: the extension only reads settings.
            let store = try FlowStore(directory: AppGroup.containerURL, readerCount: 1, smallCache: true)
            let ca = try CAStore(accessGroup: AppGroup.keychainAccessGroup).loadOrCreate()
            let poster = ThrottledPoster(IPCConstants.dbChanged)
            let recorder = FlowRecorder(store: store) { poster.signal() }
            let events = self.events

            var opts = TunnelEngine.Options(ca: ca, sink: recorder)
            opts.excludedHosts = try store.setting(Settings.excludedHosts)
            opts.decryptAll = try store.setting(Settings.decryptAllHosts)
            opts.sslProxyingHosts = try store.setting(Settings.sslProxyingHosts)
            opts.autoPinning = try store.setting(Settings.autoPinning)
            opts.http2Enabled = try store.setting(Settings.http2Enabled)
            opts.pinnedHosts = try store.pinnedHosts()
            opts.onPinned = { host in
                try? store.setPinned(host, true)
                events.push(.hostPinned(host))
            }
            opts.onLowMemoryChange = { events.push(.lowMemory($0)) }
            let scripts = ScriptRunner { events.push(.scriptLog($0)) }
            scripts.load(store.scriptSources())
            self.scripts = scripts
            let rules = RuleEngine(rules: Self.loadRules(store), rulesDirectory: store.rulesDirectory,
                                   breakpoints: BreakpointCenter(directory: store.breakpointsDirectory, onPause: { item in
                                       events.push(.breakpoint(item))
                                       Self.notify(item)
                                   }, onDrop: { id in
                                       events.push(.breakpointDropped(id))
                                       Self.withdrawNotification(id)
                                   }), scripts: scripts)
            opts.rules = rules
            self.rules = rules
            let stats = self.stats
            let engine = TunnelEngine(options: opts) { [weak self] packets in
                stats.add(out: packets.count)
                if stats.shouldTrace() { TunnelLog.write("write \(packets.count): " + packets.map(PacketStats.describe).joined(separator: ", ")) }
                let protocols = packets.map { NSNumber(value: ($0.first ?? 0) >> 4 == 6 ? AF_INET6 : AF_INET) }
                self?.packetFlow.writePackets(packets, withProtocols: protocols)
            }
            self.store = store
            self.recorder = recorder
            self.engine = engine
            self.startedAt = Date()
            TunnelLog.write("start")

            let ipv6 = Self.currentPathSupportsIPv6()
            ipv6Routed = ipv6
            TunnelLog.write("physical network IPv6: \(ipv6)")
            setTunnelNetworkSettings(Self.networkSettings(ipv6: ipv6)) { [weak self] error in
                guard let self else { return }
                if let error {
                    TunnelLog.write("settings failed: \(error)")
                    completionHandler(error)
                    return
                }
                do {
                    try engine.start()
                } catch {
                    completionHandler(error)
                    return
                }
                readPackets()
                startQuotaTimer(store: store)
                startStatsTimer()
                observePath()
                completionHandler(nil)
            }
        } catch {
            TunnelLog.write("start failed: \(error)")
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        TunnelLog.write("stop reason=\(reason.rawValue)")
        try? store?.setSetting(Settings.lastStop, StopInfo(reason: reason.rawValue, at: Date()))
        quotaTimer?.cancel()
        pathMonitor.cancel()
        engine?.stop()
        recorder?.flush()
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let message = try? IPCCodec.decode(AppMessage.self, from: messageData) else {
            completionHandler?(IPCCodec.encode(ProviderReply.error("Unreadable message")))
            return
        }
        nonisolated(unsafe) let completion = completionHandler
        let reply: @Sendable (ProviderReply) -> Void = { completion?(IPCCodec.encode($0)) }
        switch message {
        case .awaitEvents:
            events.wait { reply(.events($0)) }
        case .stats:
            reply(.stats(TunnelStats(startedAt: startedAt, activeConnections: engine?.activeConnections ?? 0,
                                     lowMemory: engine?.isLowMemory ?? false,
                                     caTrusted: engine?.pinning.caTrusted ?? false)))
        case .reloadSettings:
            if let store, let engine {
                engine.updateExcludedHosts((try? store.setting(Settings.excludedHosts)) ?? [])
                engine.updateSSLProxying(decryptAll: (try? store.setting(Settings.decryptAllHosts)) ?? false,
                                         hosts: (try? store.setting(Settings.sslProxyingHosts)) ?? [])
                engine.pinning.setEnabled((try? store.setting(Settings.autoPinning)) ?? false)
                engine.updateHTTP2((try? store.setting(Settings.http2Enabled)) ?? true)
                engine.pinning.replacePinned((try? store.pinnedHosts()) ?? [])
                rules?.update(Self.loadRules(store))
                scripts?.load(store.scriptSources())
            }
            reply(.ok)
        case .send(let flowID, let request):
            guard let engine, let store else { reply(.error("The tunnel is not running.")); return }
            engine.send(flowID: flowID, request: request, body: store.bodies.read(flowID: flowID, side: .request))
            reply(.ok)
        case .resumeBreakpoint(let id, let decision):
            reply(rules?.breakpoints.resolve(id: id, decision: decision) == true ? .ok : .error("This breakpoint is no longer waiting."))
        case .pendingBreakpoints:
            reply(.breakpoints(rules?.breakpoints.pending() ?? []))
        case .resetScriptState:
            scripts?.resetShared()
            reply(.ok)
        case .clearSession:
            recorder?.flush()
            try? store?.deleteAllFlows()
            DarwinNotifier.post(IPCConstants.dbChanged)
            reply(.ok)
        }
    }

    private func readPackets() {
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self, let engine else { return }
            stats.add(in: packets.count)
            if stats.shouldTrace() { TunnelLog.write("read \(packets.count): " + packets.map(PacketStats.describe).joined(separator: ", ")) }
            engine.handle(packets)
            if stats.shouldTrace() { TunnelLog.write("handled; re-arming read") }
            readPackets()
        }
    }

    /// Every 5 s, logs packet counters and live connections (Console / idevicesyslog: com.passage.io.tunnel).
    private func startStatsTimer() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in
            guard let self, let engine else { return }
            let (pin, pout) = stats.snapshot()
            TunnelLog.write("stats packets in=\(pin) out=\(pout) tcp=\(engine.activeConnections)")
        }
        t.resume()
        statsTimer = t
    }

    private func startQuotaTimer(store: FlowStore) {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 30, repeating: 60)
        t.setEventHandler {
            let quota = (try? store.setting(Settings.quotaBytes)) ?? Settings.quotaBytes.defaultValue
            _ = try? store.enforceQuota(maxBytes: quota)
        }
        t.resume()
        quotaTimer = t
    }

    /// Wi-Fi ↔ cellular: sockets bound to the old interface are dead; drop flows so clients reconnect.
    private func observePath() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let id = path.availableInterfaces.first { $0.type != .other }.map { "\($0.type)-\($0.name)" } ?? "none"
            if let last = lastInterface, last != id {
                TunnelLog.write("network changed \(last) -> \(id)")
                engine?.dropAllConnections()
            }
            lastInterface = id
            if path.status == .satisfied, path.supportsIPv6 != ipv6Routed {
                ipv6Routed = path.supportsIPv6
                TunnelLog.write("physical network IPv6 now \(ipv6Routed); re-applying settings")
                setTunnelNetworkSettings(Self.networkSettings(ipv6: ipv6Routed)) { error in
                    if let error { TunnelLog.write("re-apply settings failed: \(error)") }
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "passage.path"))
    }

    /// Each TCP flow holds 3 fds (socketpair + upstream) and each UDP/DNS session one;
    /// the default soft limit (~256) is far too low for a busy device.
    static func raiseFileLimit(target: rlim_t = 8192) {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else {
            TunnelLog.write("getrlimit failed errno=\(errno)")
            return
        }
        let old = limit.rlim_cur
        let wanted = min(limit.rlim_max, target)
        guard wanted > old else {
            TunnelLog.write("fd limit \(old) (hard \(limit.rlim_max))")
            return
        }
        limit.rlim_cur = wanted
        if setrlimit(RLIMIT_NOFILE, &limit) == 0 {
            TunnelLog.write("fd limit \(old) -> \(wanted)")
        } else {
            TunnelLog.write("setrlimit \(wanted) failed errno=\(errno); fd limit stays \(old)")
        }
    }

    /// Reads the physical network's IPv6 support once (the tunnel is not up yet, so this is Wi-Fi/cellular).
    static func currentPathSupportsIPv6() -> Bool {
        let monitor = NWPathMonitor()
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var supports = false
        monitor.pathUpdateHandler = { path in
            supports = path.supportsIPv6
            done.signal()
        }
        monitor.start(queue: DispatchQueue(label: "passage.path.probe"))
        _ = done.wait(timeout: .now() + 1)
        monitor.cancel()
        return supports
    }

    static func networkSettings(ipv6: Bool) -> NEPacketTunnelNetworkSettings {
        let s = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let v4 = NEIPv4Settings(addresses: [interfaceIPv4], subnetMasks: ["255.254.0.0"])
        v4.includedRoutes = [NEIPv4Route.default()]
        s.ipv4Settings = v4
        if ipv6 {
            let v6 = NEIPv6Settings(addresses: [interfaceIPv6], networkPrefixLengths: [64])
            v6.includedRoutes = [NEIPv6Route.default()]
            s.ipv6Settings = v6
        }
        // A full tunnel without DNS settings leaves iOS with no resolver at all (nothing resolves,
        // verified on iOS 17). Point DNS at public resolvers: the queries enter the tunnel through
        // the default route, UDPRelay forwards them and records them as DNS flows.
        let dns = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])
        dns.matchDomains = [""]
        s.dnsSettings = dns
        s.mtu = 1500
        return s
    }
}

/// Packet counters for the periodic stats log.
final class PacketStats: @unchecked Sendable {
    private let lock = NSLock()
    private var packetsIn = 0
    private var packetsOut = 0
    func add(in n: Int = 0, out m: Int = 0) { lock.withLock { packetsIn += n; packetsOut += m } }
    func snapshot() -> (Int, Int) { lock.withLock { (packetsIn, packetsOut) } }
    private var traced = 0
    /// True for the first 200 trace lines only.
    func shouldTrace() -> Bool { lock.withLock { traced += 1; return traced <= 200 } }

    /// "v4 udp 198.18.0.2:5353>8.8.8.8:53 len 60"
    static func describe(_ p: Data) -> String {
        let b = [UInt8](p.prefix(60))
        guard let f = b.first else { return "empty" }
        if f >> 4 == 4, b.count >= 24 {
            let ihl = Int(f & 0x0f) * 4
            let proto = b[9]
            let src = b[12..<16].map(String.init).joined(separator: "."), dst = b[16..<20].map(String.init).joined(separator: ".")
            let ports = b.count >= ihl + 4 ? ":\(Int(b[ihl]) << 8 | Int(b[ihl+1]))>\(dst):\(Int(b[ihl+2]) << 8 | Int(b[ihl+3]))" : ">\(dst)"
            let flags = proto == 6 && b.count > ihl + 13 ? " f=\(String(b[ihl+13], radix: 16))" : ""
            return "v4 p\(proto) \(src)\(ports)\(flags) len \(p.count)"
        }
        if f >> 4 == 6, b.count >= 40 { return "v6 nh\(b[6]) len \(p.count)" }
        return "?\(f) len \(p.count)"
    }
}

extension PacketTunnelProvider {
    static func loadRules(_ store: FlowStore) -> RuleSet {
        RuleSet(rules: (try? store.rules()) ?? [], enabledTools: (try? store.setting(Settings.enabledTools)) ?? RuleTool.enabledByDefault)
    }

    /// Tells the user a request is waiting, so they can open the app even when it is in the background.
    static func notify(_ item: BreakpointItem) {
        let content = UNMutableNotificationContent()
        content.title = item.phase == .request ? "Request Paused" : "Response Paused"
        content.body = "\(item.method) \(item.url)"
        content.sound = .default
        content.threadIdentifier = "breakpoints"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: item.id.uuidString, content: content, trigger: nil))
    }

    static func withdrawNotification(_ id: UUID) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id.uuidString])
    }
}
