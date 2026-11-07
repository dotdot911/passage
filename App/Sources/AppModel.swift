import CertKit
import Foundation
import IPC
import Observation
import ProxyModel
import Storage
import UserNotifications
#if os(iOS)
import UIKit
#endif

enum ListMode: String, CaseIterable { case domain, timeline }

enum AppTab: String, Hashable { case traffic, compose, rules, settings }

/// A request shown in the Copy as… sheet.
struct CodeSheetRequest: Identifiable {
    let id = UUID()
    let request: ComposedRequest
}

/// A screen pushed on the Traffic tab's navigation stack.
enum Route: Hashable {
    case domain(String)
    case flow(FlowRecord)
    case diff(FlowRecord, FlowRecord)
    case compose(ComposeDraft)
}

/// App-wide state: tunnel, recorded flows, warnings.
@MainActor @Observable
final class AppModel {
    let tunnel = TunnelController()
    private(set) var store: FlowStore?
    /// Domain mode: flows of `openHost`. Timeline mode: all matching flows.
    private(set) var flows: [FlowRecord] = []
    /// Domain mode: one row per host.
    private(set) var domains: [DomainSummary] = []
    /// The Mac sidebar's apps, most recent first.
    private(set) var clients: [ClientSummary] = []
    /// The app picked in the Mac sidebar. Not saved, unlike `filter`.
    var client: String? { didSet { reload() } }
    /// The Mac sidebar lists domains and apps beside the flow table, so both load on every reload.
    var loadsSidebar = false
    private(set) var marks: [UUID: FlowMark] = [:]
    /// Why the last list query failed (bad regex, database error); the old list stays on screen.
    private(set) var listError: String?
    /// Flows the current filter hides only because they go to Apple services.
    private(set) var hiddenAppleCount = 0
    /// The host filter of the last list query that finished: nil for Traffic, a host for a domain screen.
    /// `hasLoaded` stays false until the first query returns, so empty states do not flash at launch.
    private(set) var loadedHost: String?
    private(set) var hasLoaded = false
    var search = "" { didSet { reload() } }
    /// Conditions picked in the search field for this search only, added on top of `filter`.
    var searchTokens: [SearchToken] = [] { didSet { reload() } }
    var mode: ListMode = .domain {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "listMode"); path = []; reload() }
    }
    var composePath: [ComposeRoute] = []
    /// Counts requests opened in Compose, so the editor column of a split view starts fresh for each.
    var composeOpens = 0
    var path: [Route] = [] {
        didSet { if Self.host(in: path) != Self.host(in: oldValue) { reload() } }
    }
    /// The domain whose requests are on screen: the innermost domain on the navigation stack.
    var openHost: String? { Self.host(in: path) }

    private static func host(in path: [Route]) -> String? {
        for route in path.reversed() { if case .domain(let h) = route { return h } }
        return nil
    }
    /// Hosts decrypted when `decryptAll` is off ("*.example.com" patterns allowed).
    private(set) var sslProxyingHosts: [String] = []
    /// "Do not decrypt" patterns and hosts skipped as pinned; either one wins over the SSL Proxying list.
    private(set) var excludedHosts: [String] = []
    private(set) var pinnedHosts: Set<String> = []
    private(set) var decryptAll = false
    /// Restored on launch, so the app opens on the tab it was left on.
    var tab = AppTab(rawValue: UserDefaults.standard.string(forKey: "selectedTab") ?? "") ?? .traffic {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: "selectedTab") }
    }
    var showCertificateGuide = false
    var showHTTPSSettings = false
    var showOnboarding = !UserDefaults.standard.bool(forKey: "onboardingDone")
    /// The first flow picked for Diff; shown in a banner until compared or cancelled.
    /// Asks the list on screen to start selecting, with this flow already selected.
    var selectionRequest: SelectionRequest?
    /// What the Compose tab is editing.
    var composeDraft = ComposeDraft()
    /// Presented app-wide so row menus and the detail toolbar share them.
    var codeSheet: CodeSheetRequest?
    var commentTarget: FlowRecord?
    var alert: AppAlert?
    /// A long export, import or save in progress, shown under the Traffic title.
    var activity: String?
    /// A file in the share sheet (exports).
    var sharedFile: SharedFile?
    /// Requests and responses held at breakpoints, oldest first.
    /// Messages held by Breakpoint rules. Each one is dropped from the list when its timeout passes,
    /// since the tunnel lets it continue without telling the app.
    var pausedBreakpoints: [BreakpointItem] = [] {
        didSet { scheduleBreakpointExpiry() }
    }
    /// Screens on show that draw their own bottom bar; the breakpoint banner moves into that bar instead of covering it.
    var bottomBarScreens = 0
    private var expiryTask: Task<Void, Never>?
    /// The breakpoint being edited.
    var editingBreakpoint: BreakpointItem?
    /// Paused messages whose client disconnected; an open editor shows that they can no longer continue.
    var droppedBreakpoints: Set<UUID> = []
    /// Edits to paused messages, kept while the editor is swiped away; removed when the message is resolved.
    var breakpointDrafts: [UUID: BreakpointDraft] = [:]
    /// All rules in display order, and the tools switched on.
    var rules: [Rule] = []
    var enabledTools: Set<RuleTool> = RuleTool.enabledByDefault
    /// A rule being created from a flow (Tools menu).
    var ruleDraft: RuleDraft?
    /// The latest `console.*` lines from scripts in the tunnel, oldest first.
    var scriptLogs: [ScriptLog] = []
    /// Flows opened from Compose or Repeat, kept fresh even when the list filter hides them.
    private(set) var watched: [UUID: FlowRecord] = [:]
    /// Persisted without `text` and `host`, which come from `search` and `openHost`.
    var filter = FlowFilter() {
        didSet {
            if let data = try? JSONEncoder().encode(filter) { UserDefaults.standard.set(data, forKey: "flowFilter") }
            reload()
        }
    }
    private var reloadScheduled = false
    private var lastReload = Date.distantPast
    /// Lists keep their order until then, so a row does not move away under a finger.
    private var listHeldUntil = Date.distantPast
    private var generation = 0
    /// Bumped whenever the extension reports new data, for views that read the store directly.
    private(set) var dbChanges = 0
    private(set) var caTrusted: Bool?
    /// End date of the root CA in the shared keychain; nil until the extension has created one.
    private(set) var caNotAfter: Date?
    private(set) var lowMemory = false
    private(set) var lastStopMessage: String?
    private(set) var storeError: String?
    private var dbObserver: DarwinObserver?

    init() {
        do {
            store = try FlowStore(directory: AppGroup.containerURL)
        } catch {
            storeError = "Couldn’t open the traffic database: \(error.localizedDescription)"
        }
        #if DEBUG
        if MockTraffic.isRequested, let store { MockTraffic.seed(store) }
        if MockTraffic.isScreenshot, let store { MockTraffic.seedRules(store) }
        #endif
        mode = UserDefaults.standard.string(forKey: "listMode").flatMap(ListMode.init(rawValue:)) ?? .domain
        #if DEBUG
        if let host = MockTraffic.openHost, mode == .domain { path = [.domain(host)] }
        #endif
        if let data = UserDefaults.standard.data(forKey: "flowFilter"), let saved = try? JSONDecoder().decode(FlowFilter.self, from: data) {
            filter = saved
        }
        sslProxyingHosts = (try? store?.setting(Settings.sslProxyingHosts)) ?? []
        loadDecryptionBlockers()
        loadRules()
        decryptAll = (try? store?.setting(Settings.decryptAllHosts)) ?? false
        if decryptAll { seedDecryptAllDefaults() }
        loadCAExpiry()
        dbObserver = DarwinObserver(IPCConstants.dbChanged) { [weak self] in
            MainActor.assumeIsolated {
                self?.dbChanges += 1
                self?.reload()
            }
        }
        tunnel.onConnected = { [weak self] in
            Task { @MainActor in
                self?.loadCAExpiry()
                await self?.checkTrust()
                await self?.refreshPausedBreakpoints()
            }
        }
        tunnel.onDisconnected = { [weak self] in
            // iOS learns trust through the tunnel; the Mac reads it from the keychain, proxy or not.
            #if os(iOS)
            self?.caTrusted = nil
            #endif
            self?.pausedBreakpoints = []
        }
        tunnel.onEvent = { [weak self] event in
            switch event {
            case .lowMemory(let low): self?.lowMemory = low
            case .hostPinned:
                self?.loadDecryptionBlockers()
                self?.reload()
            case .breakpoint(let item):
                if self?.pausedBreakpoints.contains(where: { $0.id == item.id }) == false { self?.pausedBreakpoints.append(item) }
            case .breakpointDropped(let id):
                self?.droppedBreakpoints.insert(id)
                self?.pausedBreakpoints.removeAll { $0.id == id }
            case .scriptLog(let log):
                self?.appendScriptLogs([log])
            }
        }
        #if os(iOS)
        // GRDB must release its locks before iOS suspends us (shared-container rule).
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            FlowStore.suspend()
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            FlowStore.resume()
            MainActor.assumeIsolated {
                self?.reload()
                Task { await self?.refreshPausedBreakpoints() }
            }
        }
        #endif
        reload()
        readLastStop()
    }

    func onAppear() async {
        await tunnel.load()
        await checkTrust()
        // A cold launch while capturing does not fire onConnected, so messages already paused would not show.
        if tunnel.isRunning { await refreshPausedBreakpoints() }
    }

    /// The saved filter plus this search's text and tokens, limited to `host` when given.
    func effectiveFilter(host: String?) -> FlowFilter {
        var f = filter
        for token in searchTokens where !token.isOn(in: f) { token.toggle(in: &f) }
        f.text = search
        f.host = host
        f.client = client
        return f
    }

    /// Coalesces bursts (search typing, `db.changed` notifications) into at most two queries a second.
    func reload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        Task {
            // Wait out both the throttle and any touch in progress; a new touch pushes the hold further.
            while true {
                let delay = max(0.5 - Date().timeIntervalSince(lastReload), listHeldUntil.timeIntervalSinceNow)
                guard delay > 0 else { break }
                try? await Task.sleep(for: .seconds(delay))
            }
            reloadScheduled = false
            lastReload = Date()
            await performReload()
        }
    }

    /// Called while the user touches the screen: live updates wait until shortly after the touch ends.
    func holdListUpdates() {
        listHeldUntil = Date().addingTimeInterval(1.5)
    }

    private func performReload() async {
        guard let store else { return }
        let f = effectiveFilter(host: openHost)
        var sidebar = f
        sidebar.client = nil
        let queriedHost = openHost
        let wantsSidebar = loadsSidebar
        let wantsDomains = mode == .domain || wantsSidebar
        let wantsFlows = mode == .timeline || openHost != nil
        let watchedIDs = Array(watched.keys)
        generation += 1
        let current = generation
        let result = await Task.detached(priority: .userInitiated) {
            Result { () throws -> ([DomainSummary], [FlowRecord], [UUID: FlowMark], [FlowRecord], Int, [ClientSummary]) in
                (wantsDomains ? try store.domainSummaries(wantsSidebar ? sidebar : f) : [],
                 wantsFlows ? try store.flows(f) : [],
                 try store.marks(),
                 try watchedIDs.compactMap { try store.flow(id: $0) },
                 try store.hiddenAppleServiceCount(f, includeHost: !wantsDomains || f.host != nil),
                 wantsSidebar ? try store.clientSummaries(sidebar) : [])
            }
        }.value
        guard current == generation else { return }
        switch result {
        case .success(let (domains, flows, marks, watchedFlows, hidden, clients)):
            self.domains = domains
            self.clients = clients
            hiddenAppleCount = hidden
            self.flows = flows
            self.marks = marks
            for f in watchedFlows { watched[f.id] = f }
            listError = nil
            loadedHost = queriedHost
            hasLoaded = true
            #if DEBUG
            if MockTraffic.openHost == queriedHost, path.count == 1, let flow = MockTraffic.pick(flows) { path.append(.flow(flow)) }
            if mode == .timeline, path.isEmpty, let host = MockTraffic.openHost, let flow = MockTraffic.pick(flows, host: host) {
                path = [.flow(flow)]
            }
            #endif
        case .failure(let error):
            listError = error.localizedDescription
        }
    }

    /// The freshest copy of a flow that is on screen.
    func live(_ flow: FlowRecord) -> FlowRecord {
        flows.first { $0.id == flow.id } ?? watched[flow.id] ?? flow
    }

    private func scheduleBreakpointExpiry() {
        expiryTask?.cancel()
        guard let next = pausedBreakpoints.map(\.deadline).min() else { return }
        expiryTask = Task { [weak self] in
            let wait = next.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled, let self else { return }
            let now = Date()
            let expired = pausedBreakpoints.filter { $0.deadline <= now }.map(\.id.uuidString)
            pausedBreakpoints.removeAll { $0.deadline <= now }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: expired)
        }
    }

    /// The latest repeat of a flow, by the original flow's ID.
    var repeats: [UUID: UUID] = [:]

    /// A flow on screen or watched, by ID.
    func record(_ id: UUID) -> FlowRecord? {
        flows.first { $0.id == id } ?? watched[id]
    }

    /// Keeps `flow` refreshed while something shows it.
    func watch(_ flow: FlowRecord) {
        watched[flow.id] = flow
        reload()
    }

    /// Keeps `flow` refreshed and shows its detail on the Traffic tab.
    func open(_ flow: FlowRecord) {
        watched[flow.id] = flow
        tab = .traffic
        path = [.flow(flow)]
        reload()
    }

    /// "Proxy On · 105 requests · 2 rules on", or the tunnel's transition.
    var captureSubtitle: String {
        if let activity { return activity }
        switch tunnel.status {
        case .connected:
            let n = mode == .domain ? domains.reduce(0) { $0 + $1.count } : flows.count
            var text = "Proxy On · \(n) request\(n == 1 ? "" : "s")"
            let on = rules.filter { $0.enabled && enabledTools.contains($0.tool) }.count
            if on > 0 { text += " · \(on) rule\(on == 1 ? "" : "s") on" }
            return text
        case .connecting, .reasserting: return "Starting…"
        case .disconnecting: return "Stopping…"
        default: return "Proxy Off"
        }
    }

    func dismissStopMessage() {
        lastStopMessage = nil
        try? store?.setSetting(Settings.lastStop, nil)
    }

    func setMark(_ mark: FlowMark, for id: UUID) {
        do { try store?.setMark(mark, for: id) } catch { listError = error.localizedDescription }
        reload()
    }

    func isSSLProxying(_ host: String) -> Bool {
        decryptAll || sslProxyingHosts.contains { Self.host(host, matches: $0) }
    }

    /// "example.com" matches only itself; "*.example.com" matches any subdomain and example.com.
    static func host(_ host: String, matches pattern: String) -> Bool {
        let p = pattern.lowercased(), h = host.lowercased()
        return p.hasPrefix("*.") ? h == p.dropFirst(2) || h.hasSuffix(p.dropFirst(1)) : h == p
    }

    func loadDecryptionBlockers() {
        excludedHosts = (try? store?.setting(Settings.excludedHosts)) ?? []
        // The tunnel skips pinned hosts only while automatic skipping is on.
        let skipping = (try? store?.setting(Settings.autoPinning)) ?? false
        pinnedHosts = skipping ? (try? store?.pinnedHosts()) ?? [] : []
    }

    /// What keeps `host` from being decrypted even when it is listed: a "Do not decrypt" pattern, or being skipped as pinned.
    func decryptionBlocker(_ host: String) -> String? {
        if let pattern = excludedHosts.first(where: { Self.host(host, matches: $0) }) { return "“\(pattern)” in Do Not Decrypt" }
        if pinnedHosts.contains(host) { return "the pinned hosts that are skipped" }
        return nil
    }

    /// Listed for decryption and not blocked, so new connections to `host` are decrypted.
    func isDecrypting(_ host: String) -> Bool { isSSLProxying(host) && decryptionBlocker(host) == nil }

    /// Adds or removes `host` from the SSL Proxying list. New connections pick it up immediately.
    /// Turning it on also lifts what would still block it: its own "Do not decrypt" entry and a pinned skip.
    func setSSLProxying(_ host: String, _ on: Bool) {
        if on, let store {
            if excludedHosts.contains(host) {
                try? store.setSetting(Settings.excludedHosts, excludedHosts.filter { $0 != host })
            }
            if pinnedHosts.contains(host) { try? store.setPinned(host, false) }
            loadDecryptionBlockers()
            if let blocker = decryptionBlocker(host) {
                alert = AppAlert(title: "\(host) Isn’t Decrypted",
                                 message: "It’s covered by \(blocker). Remove that entry in Settings › HTTPS Decryption to decrypt it.")
            }
        }
        var hosts = sslProxyingHosts.filter { $0 != host }
        if on { hosts.append(host) }
        saveSSLProxying(hosts: hosts, decryptAll: decryptAll)
    }

    func saveSSLProxying(hosts: [String], decryptAll: Bool) {
        do {
            try store?.setSetting(Settings.sslProxyingHosts, hosts)
            try store?.setSetting(Settings.decryptAllHosts, decryptAll)
            sslProxyingHosts = hosts
            self.decryptAll = decryptAll
        } catch { listError = error.localizedDescription }
        Task { await settingsChanged() }
    }

    /// Adds `host` to "Do not decrypt" so its connections pass through untouched.
    func stopDecrypting(_ host: String) {
        guard let store else { return }
        var excluded = (try? store.setting(Settings.excludedHosts)) ?? []
        guard !excluded.contains(host) else { return }
        excluded.append(host)
        do { try store.setSetting(Settings.excludedHosts, excluded) } catch { listError = error.localizedDescription }
        if !decryptAll { setSSLProxying(host, false) } else { Task { await settingsChanged() } }
    }

    /// The first time "Decrypt all" is turned on, Apple's services go to "Do not decrypt" (they reject the CA)
    /// and pinned hosts start being skipped automatically.
    func seedDecryptAllDefaults() {
        guard let store, !UserDefaults.standard.bool(forKey: "decryptAllSeeded") else { return }
        UserDefaults.standard.set(true, forKey: "decryptAllSeeded")
        var excluded = (try? store.setting(Settings.excludedHosts)) ?? []
        for suffix in FlowFilter.appleServiceSuffixes where !excluded.contains("*." + suffix) { excluded.append("*." + suffix) }
        try? store.setSetting(Settings.excludedHosts, excluded)
        try? store.setSetting(Settings.autoPinning, true)
    }

    func toggleFavorite(_ host: String) {
        let isFavorite = domains.first { $0.host == host }?.isFavorite ?? false
        do { try store?.setFavorite(host, !isFavorite) } catch { listError = error.localizedDescription }
        reload()
    }

    func toggleTunnel() async {
        if tunnel.isRunning { await tunnel.stop() } else { await tunnel.start() }
    }

    func clearSession() async {
        if await tunnel.send(.clearSession) == nil { try? store?.deleteAllFlows() }
        path = []
        watched = [:]
        reload()
    }

    func settingsChanged() async {
        loadDecryptionBlockers()
        _ = await tunnel.send(.reloadSettings)
    }

    /// On iOS the internal site answers https://198.18.0.1/check only when the tunnel runs and this device trusts
    /// the Passage CA. On the Mac the login keychain's trust settings say it directly.
    func checkTrust() async {
        #if os(macOS)
        caTrusted = CertificateTrust.isTrusted()
        #else
        guard tunnel.isRunning else { caTrusted = nil; return }
        #if DEBUG
        if MockTraffic.isScreenshot { caTrusted = true; return }
        #endif
        var req = URLRequest(url: URL(string: "https://198.18.0.1/check")!)
        req.timeoutInterval = 5
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            caTrusted = (response as? HTTPURLResponse)?.statusCode == 200 && data == Data("ok".utf8)
        } catch {
            caTrusted = false
        }
        #endif
    }

    func regenerateCA() async throws {
        try CAStore(accessGroup: AppGroup.keychainAccessGroup).delete()
        caTrusted = false
        if tunnel.isRunning {
            await tunnel.stop()
            for _ in 0..<50 where tunnel.status != .disconnected {
                try? await Task.sleep(for: .milliseconds(100))
            }
            await tunnel.start()
        }
        loadCAExpiry()
    }

    var caExpiry: CAExpiry? { caNotAfter.map { CAExpiry.of(notAfter: $0) } }

    func loadCAExpiry() {
        caNotAfter = (try? CAStore(accessGroup: AppGroup.keychainAccessGroup).load())?.certificate.notValidAfter
    }

    private func readLastStop() {
        guard let info = try? store?.setting(Settings.lastStop) else { return }
        // 1 = userInitiated; the others are explained by `stopReasonText`.
        guard info.reason != 1, Date().timeIntervalSince(info.at) < 7 * 86_400 else { return }
        lastStopMessage = "The proxy stopped at \(info.at.formatted(date: .abbreviated, time: .shortened)): \(Self.stopReasonText(info.reason))."
    }

    /// `NEProviderStopReason` in words.
    static func stopReasonText(_ reason: Int) -> String {
        switch reason {
        case 2: "the proxy extension failed"
        case 3: "no network was available"
        case 4: "the network changed and couldn’t be recovered"
        case 5, 9: "the VPN configuration was disabled"
        case 7: "the configuration couldn’t be applied"
        case 8: "it was idle for too long"
        case 10: "the VPN configuration was removed"
        case 11: "another VPN was started"
        case 12, 13: "you signed out or switched users"
        case 14: "the connection failed"
        case 15: "the device went to sleep"
        case 16: "the app was updated"
        default: "an unknown reason (code \(reason))"
        }
    }
}

/// An error or notice shown as an alert: a title naming what happened and an optional detail.
struct AppAlert {
    let title: String
    var message: String?
}

/// A request to enter Select mode; a new `token` each time so the same flow can be asked for twice.
struct SelectionRequest: Equatable {
    let flowID: UUID
    var token = UUID()
}

/// What the breakpoint editor holds for one paused message.
struct BreakpointDraft {
    var method: String
    var url: String
    var status: Int
    var headers: [EditableHeader]
    var bodyText: String
    var binaryBody: Data?
}
