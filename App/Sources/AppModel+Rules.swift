import Foundation
import IPC
import ProxyModel
import Rules
import Storage
import UserNotifications
import Viewing

/// A rule being edited, plus the Map Local body that goes with it.
struct RuleDraft: Identifiable {
    var id: UUID { rule.id }
    var rule: Rule
    /// Map Local body; nil keeps whatever file the rule already has.
    var body: Data?
    /// Script code; nil keeps whatever file the rule already has.
    var code: String?
    var isNew: Bool
}

extension RuleTool {
    var title: String {
        switch self {
        case .breakpoint: "Breakpoint"
        case .mapLocal: "Map Local"
        case .mapRemote: "Map Remote"
        case .blockList: "Block List"
        case .allowList: "Allow List"
        case .dnsSpoof: "DNS Spoofing"
        case .networkConditions: "Network Conditions"
        case .noCaching: "No Caching"
        case .script: "Scripting"
        }
    }

    var symbol: AppSymbol {
        switch self {
        case .breakpoint: .pauseCircle
        case .mapLocal: .document
        case .mapRemote: .altRoute
        case .blockList: .block
        case .allowList: .verifiedUser
        case .dnsSpoof: .dns
        case .networkConditions: .speed
        case .noCaching: .databaseOff
        case .script: .dataObject
        }
    }

    var summary: String {
        switch self {
        case .breakpoint: "Pause matching requests or responses and edit them before they continue."
        case .mapLocal: "Answer matching requests with a response you write or import, without reaching the server."
        case .mapRemote: "Send matching requests to another host, port or path."
        case .blockList: "Block matching requests or whole hosts."
        case .allowList: "Record and decrypt only matching hosts. Everything else passes through without being recorded."
        case .dnsSpoof: "Answer DNS lookups for matching hosts with your own IP addresses."
        case .networkConditions: "Limit bandwidth, add latency or drop all traffic for matching hosts."
        case .noCaching: "Strip caching headers so every request reaches the server."
        case .script: "Read and change matching requests and responses with JavaScript."
        }
    }

    /// The action a new rule of this tool starts with.
    var defaultAction: RuleAction {
        switch self {
        case .breakpoint: .breakpoint(request: true, response: true)
        case .mapLocal: .mapLocal(status: 200, headers: [HeaderField(name: "Content-Type", value: "application/json")])
        case .mapRemote: .mapRemote(target: "")
        case .blockList: .block
        case .allowList: .allow
        case .dnsSpoof: .dnsSpoof(addresses: [])
        case .networkConditions: .networkConditions(NetworkProfile.presets[0].profile)
        case .noCaching: .noCaching
        case .script: .script(request: true, response: true)
        }
    }
}

extension AppModel {
    func loadRules() {
        rules = (try? store?.rules()) ?? []
        enabledTools = (try? store?.setting(Settings.enabledTools)) ?? RuleTool.enabledByDefault
    }

    func rules(for tool: RuleTool) -> [Rule] { rules.filter { $0.tool == tool } }

    func setTool(_ tool: RuleTool, enabled: Bool) {
        var tools = enabledTools
        if enabled { tools.insert(tool) } else { tools.remove(tool) }
        try? store?.setSetting(Settings.enabledTools, tools)
        loadRules()
        Task { await settingsChanged() }
    }

    func newRuleDraft(_ tool: RuleTool, pattern: String = "") -> RuleDraft {
        RuleDraft(rule: Rule(tool: tool, name: "", match: URLMatch(pattern: pattern), action: tool.defaultAction), body: nil,
                  code: tool == .script ? ScriptTemplate.blank.code : nil, isNew: true)
    }

    /// A new script that starts from `template`.
    func newScriptDraft(_ template: ScriptTemplate) -> RuleDraft {
        var draft = newRuleDraft(.script)
        draft.code = template.code
        draft.rule.action = template.action
        return draft
    }

    /// A new, unsaved copy of `rule` with its body or code.
    func duplicateDraft(_ rule: Rule) -> RuleDraft {
        var copy = rule
        copy.id = UUID()
        copy.name = rule.name + " Copy"
        return RuleDraft(rule: copy, body: rule.tool == .mapLocal ? ruleBody(rule.id) : nil,
                         code: rule.tool == .script ? ruleCode(rule.id) : nil, isNew: true)
    }

    /// Validates and saves a rule (and its Map Local body), then tells the tunnel.
    /// - Returns: the problem, or nil when saved.
    func save(_ draft: RuleDraft) -> String? {
        var rule = draft.rule
        if case .mapRemote(let target) = rule.action {
            rule.action = .mapRemote(target: MapRemoteTarget.normalized(target.trimmingCharacters(in: .whitespaces)))
        }
        if rule.name.trimmingCharacters(in: .whitespaces).isEmpty { rule.name = rule.match.pattern }
        do { try RuleSet.validate(rule) } catch { return error.description }
        guard let store else { return "The traffic database isn’t available." }
        do {
            if draft.body != nil || draft.code != nil {
                try FileManager.default.createDirectory(at: store.rulesDirectory, withIntermediateDirectories: true)
            }
            if let body = draft.body { try body.write(to: store.ruleBodyURL(rule.id)) }
            if let code = draft.code { try Data(code.utf8).write(to: store.ruleScriptURL(rule.id)) }
            try store.saveRule(rule)
        } catch { return error.localizedDescription }
        if rule.tool == .breakpoint { requestNotificationPermission() }
        // A new rule in a switched-off tool would never run; adding one means the user wants the tool on.
        if draft.isNew && rule.enabled && !enabledTools.contains(rule.tool) { setTool(rule.tool, enabled: true) }
        loadRules()
        Task { await settingsChanged() }
        return nil
    }

    func setRule(_ rule: Rule, enabled: Bool) {
        var r = rule
        r.enabled = enabled
        try? store?.saveRule(r)
        loadRules()
        Task { await settingsChanged() }
    }

    /// Deletes rules with their body or code; with an undo manager, Undo (shake, ⌘Z) puts them back.
    func deleteRules(_ ids: [UUID], undoManager: UndoManager? = nil) {
        let removed = rules.filter { ids.contains($0.id) }.map {
            RuleDraft(rule: $0, body: $0.tool == .mapLocal ? ruleBody($0.id) : nil,
                      code: $0.tool == .script ? ruleCode($0.id) : nil, isNew: true)
        }
        for id in ids { try? store?.deleteRule(id: id) }
        loadRules()
        Task { await settingsChanged() }
        guard let undoManager, !removed.isEmpty else { return }
        undoManager.registerUndo(withTarget: self) { model in
            for draft in removed { _ = model.save(draft) }
        }
        undoManager.setActionName(removed.count == 1 ? "Delete Rule" : "Delete Rules")
    }

    /// Reorders one tool's rules; the other tools keep their order.
    func moveRules(of tool: RuleTool, from: IndexSet, to: Int) {
        var list = rules(for: tool)
        list.move(fromOffsets: from, toOffset: to)
        try? store?.setRuleOrder(list.map(\.id))
        loadRules()
        Task { await settingsChanged() }
    }

    func ruleCode(_ id: UUID) -> String? {
        guard let url = store?.ruleScriptURL(id) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func ruleBody(_ id: UUID) -> Data? {
        guard let url = store?.ruleBodyURL(id) else { return nil }
        return try? Data(contentsOf: url)
    }

    // MARK: Rules from a flow

    /// `scheme://host/path*`: the flow's URL without its query.
    func pattern(for flow: FlowRecord) -> String {
        guard let url = flow.url, var c = URLComponents(string: url) else { return flow.host }
        c.query = nil
        c.fragment = nil
        return (c.string ?? url) + "*"
    }

    func draft(_ tool: RuleTool, from flow: FlowRecord, hostOnly: Bool = false) async -> RuleDraft {
        var draft = newRuleDraft(tool, pattern: hostOnly ? flow.host : pattern(for: flow))
        draft.rule.name = hostOnly ? flow.host : "\(flow.method ?? "") \(flow.pathText)"
        switch tool {
        case .mapLocal:
            let headers = flow.responseHeaders.filter { !["content-encoding", "content-length", "transfer-encoding"].contains($0.name.lowercased()) }
            draft.rule.action = .mapLocal(status: flow.statusCode ?? 200, headers: headers)
            let bodies = store?.bodies
            draft.body = await Task.detached(priority: .userInitiated) { () -> Data? in
                guard let prefix = bodies?.readPrefix(flowID: flow.id, side: .response, maxBytes: BodyPreview.maxRawBytes) else { return nil }
                return BodyDecoder.decode(prefix.data, contentEncoding: flow.responseHeaders.value(for: "Content-Encoding")).data
            }.value ?? Data()
        case .mapRemote:
            if let url = flow.url, let c = URLComponents(string: url), let scheme = c.scheme, let host = c.host {
                draft.rule.action = .mapRemote(target: "\(scheme)://\(host)")
            }
        default:
            break
        }
        return draft
    }

    // MARK: Breakpoints

    func refreshPausedBreakpoints() async {
        guard case .breakpoints(let items)? = await tunnel.send(.pendingBreakpoints) else { return }
        pausedBreakpoints = items
        // Messages that timed out or were resolved elsewhere should not leave notifications behind.
        let live = Set(items.map(\.id.uuidString))
        let center = UNUserNotificationCenter.current()
        let stale = await center.deliveredNotifications()
            .filter { $0.request.content.threadIdentifier == "breakpoints" && !live.contains($0.request.identifier) }
            .map(\.request.identifier)
        if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
    }

    /// Opens the editor for a paused message, e.g. after its notification is tapped.
    func openBreakpoint(id: String) async {
        await refreshPausedBreakpoints()
        guard let item = pausedBreakpoints.first(where: { $0.id.uuidString == id }) else { return }
        presentBreakpoint(item)
    }

    func breakpointBodyURL(_ item: BreakpointItem) -> URL? {
        store?.breakpointsDirectory.appendingPathComponent("\(item.id.uuidString).body")
    }

    /// Sends the decision; an edited body is written to the item's file first.
    func resolve(_ item: BreakpointItem, decision: BreakpointDecision, body: Data?) async {
        if let body, let url = breakpointBodyURL(item) { try? body.write(to: url) }
        pausedBreakpoints.removeAll { $0.id == item.id }
        editingBreakpoint = nil
        breakpointDrafts[item.id] = nil
        if case .error(let message)? = await tunnel.send(.resumeBreakpoint(id: item.id, decision: decision)) {
            alert = AppAlert(title: "Couldn’t Resume Request", message: message)
        }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [item.id.uuidString])
        reload()
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Whether the user turned notifications off, so paused messages cannot alert them in the background.
    func notificationsDenied() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }
}

/// Checks and tidies the URL a Map Remote rule sends requests to.
enum MapRemoteTarget {
    /// A pasted URL after a typed scheme ("https://https://host") keeps only the last scheme.
    static func normalized(_ text: String) -> String {
        guard let match = text.firstMatch(of: /^(?:https?:\/\/)+(https?:\/\/)/.ignoresCase()) else { return text }
        return String(match.1) + text[match.range.upperBound...]
    }

    /// Why `target` can't be used, or nil when it is an http or https URL with a host.
    static func problem(_ target: String) -> String? {
        let text = target.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return "Enter the URL to send requests to." }
        guard let url = URLComponents(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return "Start the URL with http:// or https://."
        }
        guard let host = url.host, host.contains(".") || host == "localhost" else {
            return "The URL needs a host name, such as staging.example.com."
        }
        return nil
    }
}
