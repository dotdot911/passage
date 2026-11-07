import Foundation
import IPC
import NetworkExtension
import Observation

/// Installs, starts and talks to the packet tunnel.
@MainActor @Observable
final class TunnelController {
    static let providerBundleID = "com.passage.io.PacketTunnel"

    private(set) var status: NEVPNStatus = .invalid
    private(set) var lastError: String?
    /// False until the saved VPN configuration has been looked up; starting before that could add a second one.
    private(set) var isLoaded = false
    /// True while start() or stop() is still talking to the system, before the VPN status changes.
    private var isSwitching = false
    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

    var isRunning: Bool { status == .connected }
    var isBusy: Bool { !isLoaded || isSwitching || [.connecting, .disconnecting, .reasserting].contains(status) }

    /// Called with each event the extension pushes while connected.
    var onEvent: ((TunnelEvent) -> Void)?
    /// Called when the status transitions to connected / away from connected.
    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?

    func clearError() { lastError = nil }

    func load() async {
        defer { isLoaded = true }
        #if DEBUG
        if MockTraffic.isScreenshot { status = .connected; return }
        #endif
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            manager = managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.providerBundleID }
            observeStatus()
            status = manager?.connection.status ?? .invalid
            if status == .connected { startEventLoop() }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func start() async {
        isSwitching = true
        defer { isSwitching = false }
        do {
            let m = try await installedManager()
            // Enabling another VPN configuration disables ours; starting it then fails with configurationDisabled.
            if !m.isEnabled {
                m.isEnabled = true
                try await m.saveToPreferences()
                try await m.loadFromPreferences()
            }
            if Self.onDemandPreferred && !m.isOnDemandEnabled {
                m.isOnDemandEnabled = true
                m.onDemandRules = [NEOnDemandRuleConnect()]
                try await m.saveToPreferences()
            }
            try m.connection.startVPNTunnel()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// With On-Demand enabled iOS would reconnect immediately, so it is switched off first.
    func stop() async {
        guard let m = manager else { return }
        isSwitching = true
        defer { isSwitching = false }
        if m.isOnDemandEnabled {
            m.isOnDemandEnabled = false
            do { try await m.saveToPreferences() } catch { lastError = error.localizedDescription }
        }
        m.connection.stopVPNTunnel()
    }

    private static let onDemandKey = "onDemandPreferred"
    static var onDemandPreferred: Bool { UserDefaults.standard.bool(forKey: onDemandKey) }

    func setOnDemand(_ enabled: Bool) async {
        UserDefaults.standard.set(enabled, forKey: Self.onDemandKey)
        do {
            let m = try await installedManager()
            m.isOnDemandEnabled = enabled
            m.onDemandRules = enabled ? [NEOnDemandRuleConnect()] : []
            try await m.saveToPreferences()
        } catch {
            lastError = error.localizedDescription
        }
    }

    var onDemandEnabled: Bool { Self.onDemandPreferred }

    /// Sends a message to the running extension. Returns nil if it is not running.
    func send(_ message: AppMessage) async -> ProviderReply? {
        guard let session = manager?.connection as? NETunnelProviderSession, status == .connected else { return nil }
        let data = IPCCodec.encode(message)
        return await withCheckedContinuation { cont in
            do {
                try session.sendProviderMessage(data) { reply in
                    cont.resume(returning: reply.flatMap { try? IPCCodec.decode(ProviderReply.self, from: $0) })
                }
            } catch {
                cont.resume(returning: nil)
            }
        }
    }

    // MARK: Private

    private func installedManager() async throws -> NETunnelProviderManager {
        if !isLoaded { await load() }
        if let manager { return manager }
        let m = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.providerBundleID
        proto.serverAddress = "Passage (on device)"
        m.protocolConfiguration = proto
        m.localizedDescription = "Passage"
        m.isEnabled = true
        try await m.saveToPreferences()
        try await m.loadFromPreferences() // required before the first start
        manager = m
        observeStatus()
        return m
    }

    private func observeStatus() {
        if let statusObserver { NotificationCenter.default.removeObserver(statusObserver) }
        guard let connection = manager?.connection else { return }
        statusObserver = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: connection, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let wasConnected = self.status == .connected
                self.status = self.manager?.connection.status ?? .invalid
                if self.status == .connected && !wasConnected {
                    self.startEventLoop()
                    self.onConnected?()
                } else if wasConnected && self.status != .connected {
                    self.onDisconnected?()
                }
            }
        }
    }

    private var eventLoop: Task<Void, Never>?

    private func startEventLoop() {
        eventLoop?.cancel()
        eventLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.status == .connected else { return }
                guard case .events(let events)? = await self.send(.awaitEvents) else {
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                for e in events { self.onEvent?(e) }
            }
        }
    }
}
