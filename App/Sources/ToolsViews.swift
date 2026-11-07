import ProxyModel
import Rules
import SwiftUI
import UniformTypeIdentifiers

/// The Rules tab: what is changing traffic right now, then every tool by group.
struct RulesHubView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: RuleDraft?
    /// Rules switched off here stay listed until the screen is shown again, so a mistaken tap can be undone in place.
    @State private var keptOff: Set<UUID> = []
    /// The tool shown in the detail column of a split view; nil on a stack, where tools push.
    var selection: Binding<RuleTool?>?
    /// Shows the console in the detail column of a split view; nil on a stack, where the console pushes.
    var openConsole: (() -> Void)?

    static let groups: [(title: String, tools: [RuleTool])] = [
        ("Modify", [.breakpoint, .mapLocal, .mapRemote, .script]),
        ("Block & Allow", [.blockList, .allowList]),
        ("Network", [.networkConditions, .dnsSpoof, .noCaching]),
    ]

    var body: some View {
        Group {
            // A selection binding on a stack makes iOS 26 push a tapped link twice.
            if let selection { AppList(selection: selection) { rows } } else { AppList { rows } }
        }
        .navigationTitle("Rules")
        .onAppear { keptOff = [] }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let openConsole {
                    Button(action: openConsole) { Label("Console", symbol: .terminal) }
                } else {
                    NavigationLink { ScriptConsoleView() } label: { Label("Console", symbol: .terminal) }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(Self.groups, id: \.title) { group in
                        Section {
                            ForEach(group.tools, id: \.self) { tool in
                                if tool == .script {
                                    Menu {
                                        ForEach(ScriptTemplate.allCases) { template in
                                            Button(template.title) { editing = model.newScriptDraft(template) }
                                        }
                                    } label: { Text("New Script") }
                                } else {
                                    Button("New \(tool.ruleNoun)…") { editing = model.newRuleDraft(tool) }
                                }
                            }
                        }
                    }
                } label: { Label("Add Rule", symbol: .add) }
            }
        }
        .sheet(item: $editing) { RuleEditor(draft: $0) }
    }

    @ViewBuilder private var rows: some View {
        let active = model.rules.filter { ($0.enabled || keptOff.contains($0.id)) && model.enabledTools.contains($0.tool) }
        if !active.isEmpty {
            Section("On Now") {
                ForEach(active) { rule in
                    HStack(spacing: 12) {
                        Button { editing = RuleDraft(rule: rule, body: nil, isNew: false) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text((rule.match.method.map { "\($0) " } ?? "") + rule.match.pattern)
                                    .font(.mono(.subheadline)).foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
                                Text([rule.tool.title, rule.name.isEmpty ? nil : "“\(rule.name)”", RuleListView.describe(rule.action)]
                                    .compactMap { $0 }.joined(separator: " · "))
                                    .font(.app(.caption)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Toggle(rule.name.isEmpty ? rule.match.pattern : rule.name, isOn: Binding(get: { rule.enabled }, set: { on in
                            if !on { keptOff.insert(rule.id) }
                            model.setRule(rule, enabled: on)
                        }))
                        .labelsHidden()
                    }
                }
            }
        }
        ForEach(Self.groups, id: \.title) { group in
            Section {
                ForEach(group.tools, id: \.self) { tool in
                    let row = SidebarRow(LocalizedStringKey(tool.title), symbol: tool.symbol, value: status(of: tool))
                    if selection != nil {
                        row.tag(tool).themedRow(selected: selection?.wrappedValue == tool)
                    } else {
                        NavigationLink { RuleListView(tool: tool) } label: { row }
                    }
                }
            } header: { Text(group.title) } footer: {
                SectionFooter {
                    if group.title == "Network" {
                        Text("Rules apply to decrypted HTTP/1.1 and HTTP/2. Block List, Allow List, DNS Spoofing and Network Conditions also work by host.")
                    } else if group.title == "Modify" && model.rules.isEmpty && selection == nil {
                        Text("Touch and hold any request in Traffic, then choose Create Rule.")
                    }
                }
            }
        }
    }

    /// How many rules are on, nothing when none, or "Off" when the tool is switched off.
    private func status(of tool: RuleTool) -> String {
        guard model.enabledTools.contains(tool) else { return "Off" }
        let count = model.rules(for: tool).filter(\.enabled).count
        return count == 0 ? "" : "\(count)"
    }
}

extension RuleTool {
    /// The thing one rule of this tool is, for "New …" menu items.
    var ruleNoun: String {
        switch self {
        case .breakpoint: "Breakpoint"
        case .mapLocal: "Map Local Rule"
        case .mapRemote: "Map Remote Rule"
        case .blockList: "Block Rule"
        case .allowList: "Allow Rule"
        case .dnsSpoof: "DNS Spoofing Rule"
        case .networkConditions: "Network Condition"
        case .noCaching: "No Caching Rule"
        case .script: "Script"
        }
    }
}

/// The rules of one tool, with the switch for the whole tool on top.
struct RuleListView: View {
    @Environment(AppModel.self) private var model
    let tool: RuleTool
    /// The rule edited in the detail column of a split view; nil on a stack, where rules open in a sheet.
    var selection: Binding<UUID?>?
    @Environment(\.undoManager) private var undoManager
    @State private var editing: RuleDraft?
    @State private var showMatches: URLMatch?

    var body: some View {
        let rules = model.rules(for: tool)
        AppList {
            Section {
                // The screen's title already names the tool.
                Toggle("Enabled", isOn: Binding(get: { model.enabledTools.contains(tool) },
                                                set: { model.setTool(tool, enabled: $0) }))
                    .accessibilityLabel(tool.title)
            } footer: { SectionFooter { Text(tool.summary) } }
            if rules.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label(emptyState: tool == .script ? "No Scripts" : "No Rules", symbol: tool.symbol)
                    } description: {
                        Text("Touch and hold a request in Traffic, then choose Create Rule.").font(.app(.body))
                    } actions: {
                        addButton(title: tool == .script ? "Add Script" : "Add Rule").labelStyle(.titleOnly)
                    }
                    .listRowBackground(Color.clear)
                }
            } else {
                Section(tool == .script ? "Scripts" : "Rules") {
                    ForEach(rules) { rule in
                        RuleRow(rule: rule) { open(rule) }
                            .themedRow(selected: selection?.wrappedValue == rule.id)
                            .contextMenu {
                                Button("Edit") { open(rule) }
                                Button("Duplicate") { editing = model.duplicateDraft(rule) }
                                Button { showMatches = rule.match } label: {
                                    Text("Show Matching Requests")
                                }
                                Button("Delete", role: .destructive) { model.deleteRules([rule.id], undoManager: undoManager) }
                            }
                            .deleteSwipe { model.deleteRules([rule.id], undoManager: undoManager) }
                    }
                    .onDelete { model.deleteRules($0.map { rules[$0].id }, undoManager: undoManager) }
                    .onMove { model.moveRules(of: tool, from: $0, to: $1) }
                }
            }
        }
        .navigationTitle(tool.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !rules.isEmpty { EditButton() }
                addButton(title: tool == .script ? "Add Script" : "Add Rule").labelStyle(.iconOnly)
            }
        }
        .sheet(item: $editing) { RuleEditor(draft: $0) }
        .navigationDestination(item: $showMatches) { MatchingFlowsView(match: $0, byHost: tool.matchesHosts) }
    }

    /// Beside the list a rule opens in the detail column; on a stack it opens in a sheet.
    private func open(_ rule: Rule) {
        if let selection {
            selection.wrappedValue = rule.id
        } else {
            editing = RuleDraft(rule: rule, body: nil, isNew: false)
        }
    }

    /// "+" for most tools; scripts start from a template.
    @ViewBuilder private func addButton(title: String) -> some View {
        if tool == .script {
            Menu {
                ForEach(ScriptTemplate.allCases) { template in
                    Button(template.title) { editing = model.newScriptDraft(template) }
                }
            } label: { Label(title, symbol: .add) }
        } else {
            Button { editing = model.newRuleDraft(tool) } label: { Label(title, symbol: .add) }
        }
    }

    static func describe(_ action: RuleAction) -> String {
        switch action {
        case .breakpoint(let req, let res), .script(let req, let res):
            [req ? "Request" : nil, res ? "Response" : nil].compactMap { $0 }.joined(separator: " + ")
        case .mapLocal(let status, _): "Responds \(status)"
        case .mapRemote(let target): "→ \(target)"
        case .block: "Blocked"
        case .allow: "Allowed"
        case .dnsSpoof(let addresses): addresses.joined(separator: ", ")
        case .networkConditions(let p):
            p.dropAll ? "100% loss" : "↓\(p.downloadKbps.map { "\($0)" } ?? "∞") ↑\(p.uploadKbps.map { "\($0)" } ?? "∞") kbps · \(p.latencyMs) ms"
        case .noCaching: "No caching"
        }
    }
}

/// One rule: its pattern, then its name and what it does, with its switch.
private struct RuleRow: View {
    @Environment(AppModel.self) private var model
    let rule: Rule
    let edit: () -> Void

    var body: some View {
        HStack {
            Button(action: edit) {
                VStack(alignment: .leading, spacing: 2) {
                    Text((rule.match.method.map { "\($0) " } ?? "") + rule.match.pattern)
                        .font(.mono(.subheadline)).lineLimit(2).truncationMode(.middle)
                    Text([rule.name == rule.match.pattern ? nil : rule.name, rule.match.isRegex ? "Regex" : nil,
                          RuleListView.describe(rule.action)].compactMap { $0 }.joined(separator: " · "))
                        .font(.app(.caption)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Toggle(rule.name.isEmpty ? rule.match.pattern : rule.name, isOn: Binding(get: { rule.enabled }, set: { model.setRule(rule, enabled: $0) }))
                .labelsHidden()
        }
    }
}

/// Recorded requests a rule's pattern matches, newest first.
struct MatchingFlowsView: View {
    @Environment(AppModel.self) private var model
    let match: URLMatch
    var byHost = false
    @State private var flows: [FlowRecord]?

    var body: some View {
        AppList(plain: true, flows ?? []) { flow in
            FlowRow(flow: flow, mark: model.marks[flow.id], actions: false)
        }
        .listStyle(.plain)
        .overlay {
            if flows == nil {
                ProgressView()
            } else if flows?.isEmpty == true {
                ContentUnavailableView("No Matching Requests", symbol: .filterList,
                                       description: Text("No recorded requests match this pattern yet."))
            }
        }
        .navigationTitle("Matching Requests")
        .navigationBarTitleDisplayMode(.inline)
        .task { flows = await model.flows(matching: match, byHost: byHost) }
    }
}

/// Pattern, method and regex, with a live count of recorded requests that match.
struct MatchSection: View {
    @Environment(AppModel.self) private var model
    @Binding var match: URLMatch
    /// The tool looks only at host names, so there is no method or path to match.
    var byHost = false
    @State private var count: Int?
    @State private var problem: String?

    var body: some View {
        Section {
            TextField("Pattern", text: $match.pattern,
                      prompt: Text(verbatim: match.isRegex ? "Regular expression" : byHost ? "api.example.com or *.example.com" : "https://api.example.com/v1/*"),
                      axis: .vertical)
                .font(.mono(.body))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .keyboardType(.URL)
            if !byHost {
                Picker("Method", selection: $match.method) {
                    Text("Any").tag(String?.none)
                    ForEach(ComposeDraft.methods, id: \.self) { Text($0).tag(Optional($0)) }
                }
            }
            Toggle("Regular Expression", isOn: $match.isRegex)
            if let count {
                NavigationLink { MatchingFlowsView(match: match, byHost: byHost) } label: {
                    LabeledContent("Matching Requests", value: count >= AppModel.maxMatches ? "\(count)+" : "\(count)")
                }
                .disabled(count == 0)
            }
        } header: { Text("Match") } footer: {
            SectionFooter {
                if let problem {
                    Text(problem).foregroundStyle(.statusError)
                } else {
                    if byHost {
                        Text(match.isRegex ? "Matched against the host name, ignoring case."
                                           : "Matches host names. * matches anything, and *.example.com also covers example.com.")
                    } else {
                        Text(match.isRegex ? "Matched anywhere in the URL, ignoring case."
                                           : "* matches anything. Without a scheme, any scheme matches. Case is ignored.")
                    }
                }
            }
        }
        .task(id: match) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            if match.pattern.trimmingCharacters(in: .whitespaces).isEmpty {
                problem = nil
                count = nil
                return
            }
            switch Result(catching: { () throws(RuleError) in try CompiledMatch(match) }) {
            case .success:
                problem = nil
                count = await model.flows(matching: match, byHost: byHost).count
            case .failure(let error):
                problem = error.description
                count = nil
            }
        }
    }
}

/// Creates or edits one rule; scripts get the code editor instead.
struct RuleEditor: View {
    let draft: RuleDraft

    var body: some View {
        Group {
            if draft.rule.tool == .script { ScriptEditor(draft: draft) } else { RuleForm(draft: draft) }
        }
        .editorSheetSizing()
    }
}

/// A rule edited in place in the detail column of a split view, with Save and Revert instead of a sheet's Cancel and Done.
struct InlineRuleEditor: View {
    let rule: Rule

    var body: some View {
        let draft = RuleDraft(rule: rule, body: nil, isNew: false)
        if rule.tool == .script {
            ScriptEditor(draft: draft, inline: true)
        } else {
            RuleForm(draft: draft, inline: true).readableWidth()
        }
    }
}

/// The form for every tool except Scripting: what to match, what to do, then the name.
private struct RuleForm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: RuleDraft
    @State private var error: String?
    @State private var importing = false
    @State private var bodyText = ""
    @State private var bodyIsBinary = false
    @State private var headers: [EditableHeader] = []
    /// The form appears again when a pushed screen is popped; it must not reload over unsaved edits.
    @State private var loaded = false
    @State private var original: (rule: Rule, bodyText: String, headers: [EditableHeader])?
    @State private var confirmDiscard = false
    /// In the detail column rather than a sheet: no stack of its own, Save keeps the editor open.
    private let inline: Bool

    init(draft: RuleDraft, inline: Bool = false) {
        _draft = State(initialValue: draft)
        self.inline = inline
    }

    private var hasChanges: Bool {
        guard let original else { return false }
        return draft.rule != original.rule || bodyText != original.bodyText || headers != original.headers
    }

    private var canSave: Bool {
        guard !draft.rule.match.pattern.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if case .mapRemote(let target) = draft.rule.action { return MapRemoteTarget.problem(MapRemoteTarget.normalized(target)) == nil }
        return true
    }

    var body: some View {
        if inline {
            form
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if hasChanges {
                            Button("Revert") { revert() }
                        }
                        ConfirmButton(title: "Save", action: save)
                            .disabled(!hasChanges || !canSave)
                            .keyboardShortcut("s", modifiers: .command)
                    }
                }
                // Picking another rule keeps these edits rather than dropping them.
                .onDisappear { if hasChanges && canSave { save() } }
        } else {
            NavigationStack {
                form
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            CancelButton { if hasChanges { confirmDiscard = true } else { dismiss() } }
                                .confirmationDialog("Discard your changes?", isPresented: $confirmDiscard) {
                                    Button("Discard Changes", role: .destructive) { dismiss() }
                                    Button("Keep Editing", role: .cancel) {}
                                }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            ConfirmButton(title: draft.isNew ? "Add" : "Done", action: save)
                                .disabled(!canSave)
                        }
                    }
                    .interactiveDismissDisabled(hasChanges)
            }
        }
    }

    private var form: some View {
        AppForm {
            MatchSection(match: $draft.rule.match, byHost: draft.rule.tool.matchesHosts)
            ActionSection(draft: $draft, bodyText: $bodyText, bodyIsBinary: $bodyIsBinary, headers: $headers, importing: $importing)
            Section("Name") {
                TextField("Name", text: $draft.rule.name,
                          prompt: Text(verbatim: draft.rule.match.pattern.isEmpty ? "Optional" : draft.rule.match.pattern))
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .keyboardDoneButton()
        .alert("Couldn’t Save Rule", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
        .navigationTitle(inline ? (draft.rule.name.isEmpty ? draft.rule.match.pattern : draft.rule.name)
                         : draft.isNew ? "New \(draft.rule.tool.ruleNoun)" : draft.rule.tool.ruleNoun)
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { error = "Couldn’t read \(url.lastPathComponent)."; return }
            setBody(data)
            if let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType {
                headers.removeAll { $0.name.lowercased() == "content-type" }
                headers.insert(EditableHeader(name: "Content-Type", value: type), at: 0)
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if case .mapLocal(_, let h) = draft.rule.action { headers = h.map { EditableHeader(name: $0.name, value: $0.value) } }
        if draft.rule.tool == .mapLocal { setBody(draft.body ?? model.ruleBody(draft.rule.id) ?? Data()) }
        original = (draft.rule, bodyText, headers)
    }

    private func setBody(_ data: Data) {
        draft.body = data
        if let text = String(data: data, encoding: .utf8) { bodyText = text; bodyIsBinary = false } else { bodyIsBinary = true }
    }

    private func save() {
        if case .mapLocal(let status, _) = draft.rule.action {
            let fields = headers.filter { $0.enabled && !$0.name.isEmpty }.map { HeaderField(name: $0.name, value: $0.value) }
            draft.rule.action = .mapLocal(status: status, headers: fields)
            if !bodyIsBinary { draft.body = Data(bodyText.utf8) }
        }
        guard inline else {
            if let problem = model.save(draft) { error = problem } else { dismiss() }
            return
        }
        // The switch in the list may have changed since the editor opened; keep it.
        if let live = model.rules.first(where: { $0.id == draft.rule.id }) { draft.rule.enabled = live.enabled }
        if let problem = model.save(draft) { error = problem } else { original = (draft.rule, bodyText, headers) }
    }

    private func revert() {
        guard let original else { return }
        draft.rule = original.rule
        bodyText = original.bodyText
        headers = original.headers
    }
}

/// The tool-specific part of the rule form.
private struct ActionSection: View {
    @Binding var draft: RuleDraft
    @Binding var bodyText: String
    @Binding var bodyIsBinary: Bool
    @Binding var headers: [EditableHeader]
    @Binding var importing: Bool
    @State private var notJSON = false
    @State private var notificationsOff = false
    @Environment(AppModel.self) private var model

    var body: some View {
        switch draft.rule.action {
        case .script:
            EmptyView()
        case .breakpoint(let request, let response):
            Section {
                Toggle("Request", isOn: Binding(get: { request }, set: { draft.rule.action = .breakpoint(request: $0, response: response) }))
                Toggle("Response", isOn: Binding(get: { response }, set: { draft.rule.action = .breakpoint(request: request, response: $0) }))
            } header: { Text("Pause On") } footer: {
                SectionFooter {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Paused messages continue unchanged after 5 minutes.")
                        if notificationsOff {
                            Text("Notifications are off, so you won’t be alerted while Passage is in the background. Turn them on in Settings › Notifications › Passage.")
                        }
                    }
                }
            }
            .task { notificationsOff = await model.notificationsDenied() }
        case .mapLocal(let status, let saved):
            Section("Response") {
                LabeledContent("Status") {
                    IntField("200", value: Binding(get: { status }, set: { draft.rule.action = .mapLocal(status: $0, headers: saved) }))
                }
            }
            Section("Headers") {
                ForEach($headers) { $h in
                    HStack {
                        TextField("Name", text: $h.name).font(.app(.caption, weight: .bold))
                        TextField("Value", text: $h.value).font(.mono(.caption))
                    }
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .deleteSwipe { headers.removeAll { $0.id == h.id } }
                }
                .onDelete { headers.remove(atOffsets: $0) }
                Button("Add Header") { headers.append(EditableHeader(name: "", value: "")) }
            }
            Section {
                if bodyIsBinary {
                    LabeledContent("Binary Body", value: ByteCountFormatter.string(fromByteCount: Int64(draft.body?.count ?? 0), countStyle: .file))
                    Button("Replace with Text", role: .destructive) { bodyIsBinary = false; bodyText = "" }
                } else {
                    TextEditor(text: $bodyText).font(.mono(.caption)).frame(minHeight: 160)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Button("Import from Files…") { importing = true }
            } header: {
                HStack {
                    Text("Body")
                    Spacer()
                    if !bodyIsBinary {
                        Menu {
                            Button("Pretty-Print JSON") { reformat(pretty: true) }
                            Button("Minify JSON") { reformat(pretty: false) }
                        } label: { Text("Format").font(.app(.caption)).textCase(nil) }
                        .headerControl()
                    }
                }
            } footer: {
                SectionFooter {
                    if notJSON { Text("The body isn’t valid JSON.").foregroundStyle(.statusError) } else { Text("Content-Length is set automatically.") }
                }
            }
            .sensoryFeedback(.error, trigger: notJSON) { _, failed in failed }
        case .mapRemote(let target):
            Section {
                TextField("Target", text: Binding(get: { target }, set: { draft.rule.action = .mapRemote(target: $0) }),
                          prompt: Text(verbatim: "https://staging.example.com"))
                    .font(.mono(.body)).keyboardType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: { Text("Send To") } footer: {
                SectionFooter {
                    if !target.isEmpty, let problem = MapRemoteTarget.problem(MapRemoteTarget.normalized(target)) {
                        Text(problem).foregroundStyle(.statusError)
                    } else {
                        Text("Without a path, the original path is kept. The query is always kept.")
                    }
                }
            }
        case .dnsSpoof(let addresses):
            Section {
                DNSAnswerField(addresses: addresses) { draft.rule.action = .dnsSpoof(addresses: $0) }
            } header: { Text("Answer With") } footer: { SectionFooter { Text("IPv4 addresses answer A lookups and IPv6 addresses answer AAAA lookups.") } }
        case .networkConditions(let profile):
            NetworkProfileSection(profile: Binding(get: { profile }, set: { draft.rule.action = .networkConditions($0) }))
        case .block, .allow, .noCaching:
            EmptyView()
        }
    }

    private func reformat(pretty: Bool) {
        if let text = JSONFormatter.format(bodyText, pretty: pretty) { bodyText = text; notJSON = false } else { notJSON = true }
    }
}

private struct NetworkProfileSection: View {
    @Binding var profile: NetworkProfile
    @State private var custom: Bool?

    private var presetIndex: Int { NetworkProfile.presets.firstIndex { $0.profile == profile } ?? -1 }

    var body: some View {
        let showCustom = custom ?? (presetIndex == -1)
        Section {
            Picker("Preset", selection: Binding(get: { showCustom ? -1 : presetIndex }, set: { index in
                custom = index < 0
                if index >= 0 { profile = NetworkProfile.presets[index].profile }
            })) {
                ForEach(NetworkProfile.presets.indices, id: \.self) { Text(NetworkProfile.presets[$0].name).tag($0) }
                Text("Custom").tag(-1)
            }
            .pickerStyle(.menu)
        }
        if showCustom && !profile.dropAll {
            Section("Custom") {
                kbps("Download", $profile.downloadKbps)
                kbps("Upload", $profile.uploadKbps)
                LabeledContent("Latency (ms)") {
                    IntField("0", value: $profile.latencyMs)
                }
            }
        }
    }

    private func kbps(_ title: String, _ value: Binding<Int?>) -> some View {
        LabeledContent("\(title) (kbps)") {
            IntField("Unlimited", value: value)
        }
    }
}

/// Keeps the typed text, separators included, and hands the parsed addresses on; parsing on every keystroke would eat the comma just typed.
private struct DNSAnswerField: View {
    @State private var text: String
    let update: ([String]) -> Void

    init(addresses: [String], update: @escaping ([String]) -> Void) {
        _text = State(initialValue: addresses.joined(separator: ", "))
        self.update = update
    }

    var body: some View {
        TextField("Addresses", text: $text, prompt: Text(verbatim: "10.0.0.5, ::1"))
            .font(.mono(.body)).keyboardType(.numbersAndPunctuation)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .onChange(of: text) {
                update(text.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init))
            }
    }
}

/// The Rules tab: a stack in compact width. In regular width the tools, the rules of the one picked, and the rule
/// being edited sit in three columns when there is room, or the editor pushes over the rules in two; the script
/// console is an inspector.
struct RulesTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var tool: RuleTool? = .breakpoint
    @State private var rule: UUID?
    @State private var showsConsole = false
    @State private var width: CGFloat = 0

    /// Wide enough for tools, rules and the editor side by side, as in Traffic.
    private static let threeColumnWidth: CGFloat = 1180

    var body: some View {
        Group {
            if sizeClass != .regular {
                NavigationStack { RulesHubView() }
            } else if width >= Self.threeColumnWidth {
                NavigationSplitView(columnVisibility: $columns) {
                    sidebar
                } content: {
                    NavigationStack { rules }
                        .id(tool)
                        .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 420)
                } detail: {
                    NavigationStack {
                        Group {
                            if let current { InlineRuleEditor(rule: current) } else { EmptyColumn("No Rule Selected") }
                        }
                        .groundContainer()
                    }
                    .id(rule)
                    .modifier(console)
                }
                .navigationSplitViewStyle(.balanced)
                .environment(\.inSplitView, true)
            } else {
                NavigationSplitView(columnVisibility: $columns) {
                    sidebar
                } detail: {
                    NavigationStack {
                        rules
                            .groundContainer()
                            .navigationDestination(item: $rule) { _ in
                                if let current { InlineRuleEditor(rule: current).groundContainer() }
                            }
                    }
                    .id(tool)
                    .modifier(console)
                }
                .navigationSplitViewStyle(.balanced)
                .environment(\.inSplitView, true)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onChange(of: tool) { rule = nil }
        #if DEBUG
        .task {
            // `-mockRule <tool>` opens the first rule of that tool, for screenshots.
            guard let picked = UserDefaults.standard.string(forKey: "mockRule").flatMap(RuleTool.init(rawValue:)) else { return }
            tool = picked
            try? await Task.sleep(for: .milliseconds(500))
            rule = model.rules.first { $0.tool == picked }?.id
        }
        #endif
    }

    private var current: Rule? {
        model.rules.first { $0.id == rule && $0.tool == tool }
    }

    private var sidebar: some View {
        RulesHubView(selection: $tool, openConsole: { showsConsole.toggle() })
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
            .toolbar(removing: .sidebarToggle)
    }

    @ViewBuilder private var rules: some View {
        if let tool { RuleListView(tool: tool, selection: $rule) } else { EmptyColumn("No Tool Selected") }
    }

    private var console: InspectorConsole { InspectorConsole(isPresented: $showsConsole) }
}

/// The script console beside the editing column.
private struct InspectorConsole: ViewModifier {
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.inspector(isPresented: $isPresented) {
            VStack(spacing: 0) { ScriptConsoleView(inInspector: true) }
                .background(Color.ground)
                .inspectorColumnWidth(min: 280, ideal: 340, max: 480)
        }
    }
}

extension RuleTool {
    /// Tools the tunnel applies per host name rather than per request.
    var matchesHosts: Bool { self == .dnsSpoof || self == .networkConditions || self == .allowList }
}
