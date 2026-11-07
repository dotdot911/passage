import ProxyModel
import SwiftUI

/// Creates or edits a script: the code fills the screen; what it matches is one tap away on the bottom bar.
struct ScriptEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: RuleDraft
    @State private var code = ""
    @State private var renaming = false
    @State private var newName = ""
    @State private var editingMatch = false
    @State private var testRun: TestRun?
    @State private var error: String?
    /// The editor appears again when Console or Reference is popped; it must not reload over unsaved edits.
    @State private var loaded = false
    @State private var original: (rule: Rule, code: String)?
    @State private var confirmDiscard = false

    /// In the detail column rather than a sheet: no stack of its own, the match sits above the code, Save keeps it open.
    private let inline: Bool

    init(draft: RuleDraft, inline: Bool = false) {
        _draft = State(initialValue: draft)
        self.inline = inline
    }

    private var hasChanges: Bool {
        guard let original else { return false }
        return draft.rule != original.rule || code != original.code
    }

    private var title: String {
        draft.rule.name.isEmpty ? (draft.isNew ? "New Script" : "Script") : draft.rule.name
    }

    var body: some View {
        if inline {
            editor
                .safeAreaInset(edge: .top, spacing: 0) {
                    HStack {
                        matchButton.buttonStyle(.bordered)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.ground)
                }
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        testButton
                        NavigationLink { ScriptReferenceView() } label: { Label("Reference", symbol: .menuBook) }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if hasChanges {
                            Button("Revert") { revert() }
                        }
                        ConfirmButton(title: "Save", action: save)
                            .disabled(!hasChanges)
                            .keyboardShortcut("s", modifiers: .command)
                    }
                }
                // Picking another script keeps these edits rather than dropping them.
                .onDisappear { if hasChanges { save() } }
        } else {
            NavigationStack {
                editor
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            CancelButton { if hasChanges { confirmDiscard = true } else { dismiss() } }
                                .confirmationDialog("Discard your changes?", isPresented: $confirmDiscard) {
                                    Button("Discard Changes", role: .destructive) { dismiss() }
                                    Button("Keep Editing", role: .cancel) {}
                                }
                        }
                        ToolbarItem(placement: .confirmationAction) { ConfirmButton(title: draft.isNew ? "Add" : "Done", action: save) }
                        ToolbarItemGroup(placement: .bottomBar) {
                            matchButton
                            Spacer()
                            testButton
                            NavigationLink { ScriptConsoleView() } label: { Label("Console", symbol: .terminal) }
                            NavigationLink { ScriptReferenceView() } label: { Label("Reference", symbol: .menuBook) }
                        }
                    }
            }
            .interactiveDismissDisabled(hasChanges)
        }
    }

    private var editor: some View {
        CodeEditor(text: $code)
            .ignoresSafeArea(.container, edges: .bottom)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarTitleMenu {
                Button("Rename…") { newName = draft.rule.name; renaming = true }
            }
            .alert("Rename Script", isPresented: $renaming) {
                TextField("Name", text: $newName)
                Button("Rename") { draft.rule.name = newName }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Couldn’t Save Script", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
            .navigationDestination(isPresented: $editingMatch) { ScriptMatchForm(draft: $draft) }
            .navigationDestination(item: $testRun) { run in
                ScriptTestList(code: run.code, name: title, match: draft.rule.match, action: draft.rule.action)
            }
            .onAppear(perform: load)
    }

    private var matchButton: some View {
        Button { editingMatch = true } label: {
            Text(matchSummary).font(.mono(.footnote)).lineLimit(1).truncationMode(.middle)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
        .accessibilityLabel("Match: \(matchSummary)")
    }

    private var testButton: some View {
        Button { testRun = TestRun(code: code) } label: { Label("Test Script", symbol: .playArrow) }
            .keyboardShortcut("r", modifiers: .command)
    }

    /// "httpbin.org/* · Response", or a prompt when there is no pattern yet.
    private var matchSummary: String {
        let pattern = draft.rule.match.pattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return "Set URL Pattern…" }
        let phases = RuleListView.describe(draft.rule.action)
        return [pattern, phases.isEmpty ? "Off" : phases].joined(separator: " · ")
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        code = draft.code ?? model.ruleCode(draft.rule.id) ?? ""
        original = (draft.rule, code)
    }

    private func save() {
        draft.code = code
        guard inline else {
            if let problem = model.save(draft) { error = problem } else { dismiss() }
            return
        }
        // The switch in the list may have changed since the editor opened; keep it.
        if let live = model.rules.first(where: { $0.id == draft.rule.id }) { draft.rule.enabled = live.enabled }
        if let problem = model.save(draft) { error = problem } else { original = (draft.rule, code) }
    }

    private func revert() {
        guard let original else { return }
        draft.rule = original.rule
        code = original.code
    }
}

/// The code as it was when Run was tapped.
private struct TestRun: Hashable {
    let id = UUID()
    let code: String
}

/// Where a script runs: the URL pattern, method and phases.
private struct ScriptMatchForm: View {
    @Binding var draft: RuleDraft

    var body: some View {
        AppForm {
            MatchSection(match: $draft.rule.match)
            if case .script(let request, let response) = draft.rule.action {
                Section("Run On") {
                    Toggle("Request", isOn: Binding(get: { request }, set: { draft.rule.action = .script(request: $0, response: response) }))
                    Toggle("Response", isOn: Binding(get: { response }, set: { draft.rule.action = .script(request: request, response: $0) }))
                }
            }
        }
        .navigationTitle("Match")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Picks a recorded flow and shows what the script does to it.
struct ScriptTestList: View {
    @Environment(AppModel.self) private var model
    let code: String
    let name: String
    let match: URLMatch
    let action: RuleAction
    @State private var flows: [FlowRecord]?

    var body: some View {
        AppList(plain: true, flows ?? []) { flow in
            NavigationLink {
                ScriptRunView(code: code, name: name, action: action, flow: flow)
            } label: {
                FlowRow(flow: flow, mark: nil, actions: false)
            }
        }
        .listStyle(.plain)
        .overlay {
            if flows == nil {
                ProgressView()
            } else if flows?.isEmpty == true {
                ContentUnavailableView("No Matching Requests", symbol: .filterList,
                                       description: Text("Make a request that matches this script’s URL pattern, then test the script on it."))
            }
        }
        .safeAreaInset(edge: .bottom) {
            Text("The script runs here in the app, on a copy of the request. $shared starts empty.")
                .font(.app(.footnote)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.bar)
        }
        .navigationTitle("Test Script")
        .navigationBarTitleDisplayMode(.inline)
        .task { flows = await model.flows(matching: match) }
    }
}

/// Runs the script on one flow and shows the result.
private struct ScriptRunView: View {
    @Environment(AppModel.self) private var model
    let code: String
    let name: String
    let action: RuleAction
    let flow: FlowRecord
    @State private var result: ScriptTestResult?

    var body: some View {
        Group {
            if let result { ScriptTestResultView(result: result) } else { ProgressView() }
        }
        .navigationTitle("Result")
        .navigationBarTitleDisplayMode(.inline)
        .task { result = await model.testScript(code, name: name, action: action, on: flow) }
    }
}

private struct ScriptTestResultView: View {
    let result: ScriptTestResult

    var body: some View {
        AppList {
            if result.phases.isEmpty {
                Text("Nothing ran. The request has no response, or both Request and Response are off.").foregroundStyle(.secondary)
            }
            ForEach(result.phases) { phase in
                Section(phase.phase == .request ? "Request" : "Response") {
                    if case .failed(let message) = phase.outcome {
                        LabeledContent("Result") { Text("Error").foregroundStyle(.statusError) }
                        Text(message.hasPrefix("Error: ") ? String(message.dropFirst(7)) : message)
                            .font(.mono(.caption)).textSelection(.enabled)
                    } else {
                        LabeledContent("Result", value: Self.describe(phase.outcome))
                    }
                    if let m = phase.message {
                        if phase.phase == .request, case .respond = phase.outcome {
                            Text("Status \(m.status ?? 200)").font(.mono(.caption))
                        } else if phase.phase == .request {
                            Text("\(m.method) \(m.url)").font(.mono(.caption))
                        } else {
                            Text("Status \(m.status ?? 0)").font(.mono(.caption))
                        }
                        ForEach(Array(m.headers.enumerated()), id: \.offset) { _, h in
                            (Text(h.name + ": ").bold() + Text(h.value)).font(.mono(.caption2))
                        }
                        if !m.body.isEmpty {
                            Text(m.bodyText.map { String($0.prefix(20000)) } ?? "\(m.body.count) bytes of binary data")
                                .font(.mono(.caption2)).textSelection(.enabled)
                        }
                    }
                }
            }
            Section("Console") {
                if result.logs.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(Array(result.logs.enumerated()), id: \.offset) { _, log in ScriptLogRow(log: log, showName: false) }
            }
        }
    }

    static func describe(_ outcome: ScriptOutcome) -> String {
        switch outcome {
        case .unchanged: "Unchanged"
        case .modified: "Edited"
        case .respond: "Mocked"
        case .abort: "Aborted"
        case .failed(let message): "Error: \(message)"
        }
    }
}

struct ScriptLogRow: View {
    let log: ScriptLog
    var showName = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if showName {
                Text("\(log.date.formatted(date: .omitted, time: .standard)) · \(log.scriptName)")
                    .font(.app(.caption2)).foregroundStyle(.secondary)
            }
            Text(log.message).font(.mono(.caption)).foregroundStyle(color).textSelection(.enabled)
        }
    }

    private var color: Color {
        switch log.level {
        case .error: .red
        case .warn: .orange
        case .log, .info: .primary
        }
    }
}

/// `console.*` output from scripts running in the tunnel, newest first.
struct ScriptConsoleView: View {
    @Environment(AppModel.self) private var model
    /// In an inspector beside other content: the controls sit in the panel instead of the shared toolbar.
    var inInspector = false
    @State private var errorsOnly = false
    @State private var resetError: String?
    @State private var search = ""

    /// Newest first, each with its position in the log so rows keep their identity as new logs arrive.
    private var shown: [(index: Int, log: ScriptLog)] {
        model.scriptLogs.enumerated().reversed().map { (index: $0.offset, log: $0.element) }.filter { item in
            (!errorsOnly || item.log.level == .error)
                && (search.isEmpty || item.log.message.localizedCaseInsensitiveContains(search)
                    || item.log.scriptName.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        if inInspector {
            VStack(spacing: 10) {
                HStack {
                    Text("Console").font(.app(.headline))
                    Spacer()
                    moreMenu.labelStyle(.iconOnly)
                }
                filter
                TextField("Message or script", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding([.horizontal, .top], 16)
            .background(Color.ground)
            log
        } else {
            log
                .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Message or script")
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .navigationTitle("Console")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) { filter.fixedSize() }
                    ToolbarItem(placement: .topBarTrailing) { moreMenu }
                }
        }
    }

    private var log: some View {
        let shown = shown
        return AppList(plain: true, shown, id: \.index) { item in ScriptLogRow(log: item.log) }
            .listStyle(.plain)
            .overlay {
                if model.scriptLogs.isEmpty {
                    ContentUnavailableView("No Output", symbol: .terminal,
                                           description: Text("console.log calls and script errors show up here while Passage is open."))
                } else if shown.isEmpty {
                    if search.isEmpty {
                        ContentUnavailableView("No Errors", symbol: .checkCircle)
                    } else {
                        ContentUnavailableView(searching: search)
                    }
                }
            }
            .alert("Couldn’t Reset $shared", isPresented: Binding(get: { resetError != nil }, set: { if !$0 { resetError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(resetError ?? "") }
    }

    private var filter: some View {
        Picker("Show", selection: $errorsOnly) {
            Text("All").tag(false)
            Text("Errors").tag(true)
        }
        .pickerStyle(.segmented)
    }

    private var moreMenu: some View {
        Menu {
            Button("Reset $shared") { Task { resetError = await model.resetScriptState() } }
            Section {
                Button("Clear Console", role: .destructive) { model.scriptLogs.removeAll() }
            }
        } label: { Label("More", symbol: .moreHoriz) }
    }
}

/// What a script can use, as a list of entries by topic.
struct ScriptReferenceView: View {
    private static let sections: [(title: String, footer: String?, entries: [(code: String, text: String)])] = [
        ("Entry Point",
         "Called for each matching request (flow.phase is \"request\") and response (\"response\"), if that phase is on. Change flow in place.",
         [("function handle(flow) { … }", "Runs once per phase")]),
        ("Flow", nil, [
            ("flow.id", "Request ID"),
            ("flow.request.method", "\"GET\", \"POST\"…"),
            ("flow.request.url", "Full URL. Change the host to send the request elsewhere"),
            ("flow.request.headers", "{ \"Name\": \"value\" }; repeated headers become arrays"),
            ("flow.request.body", "Text (decompressed), or null if not UTF-8"),
            ("flow.request.bodyBytes", "Uint8Array (decompressed)"),
            ("flow.response", "{ status, headers, body, bodyBytes } in the response phase"),
            ("flow.response = {…}", "In the request phase, answers without contacting the server"),
            ("flow.abort()", "Close the connection"),
        ]),
        ("Bodies",
         "A changed body is sent uncompressed with a new Content-Length.",
         [("body", "A string, an object (sent as JSON) or null"), ("bodyBytes", "Wins over body when both are set")]),
        ("Helpers", nil, [
            ("console.log/info/warn/error(…)", "Writes to the Console"),
            ("btoa(s), atob(s)", "Base64 of a binary string"),
            ("base64.encode(x), base64.decode(s)", "Text or bytes to Base64, and back to bytes"),
            ("utf8.encode(s), utf8.decode(bytes)", "Text to bytes and back"),
            ("crypto.md5/sha1/sha256/sha512(x)", "Hex digest of text or bytes"),
            ("crypto.hmac(\"sha256\", key, message)", "Hex HMAC"),
            ("$shared", "Object shared by all scripts until the proxy stops"),
        ]),
        ("Limits",
         "Errors let the traffic through unchanged and are noted on the request.",
         [("2 s", "Longest run"), ("10 MB", "Largest body a script sees")]),
    ]

    @State private var width: CGFloat = 0

    /// Wide enough to set each entry's code beside its description, as a reference table.
    private var tabular: Bool { width >= 560 }

    var body: some View {
        AppList {
            ForEach(Self.sections, id: \.title) { section in
                Section {
                    ForEach(section.entries, id: \.code) { entry in
                        if tabular {
                            HStack(alignment: .firstTextBaseline, spacing: 16) {
                                Text(entry.code).font(.mono(.subheadline)).textSelection(.enabled)
                                    .frame(width: width * 0.45, alignment: .leading)
                                Text(entry.text).font(.app(.subheadline)).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .accessibilityElement(children: .combine)
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.code).font(.mono(.subheadline)).textSelection(.enabled)
                                Text(entry.text).font(.app(.caption)).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: { Text(section.title) } footer: {
                    SectionFooter {
                        if let footer = section.footer { Text(footer) }
                    }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .navigationTitle("Script Reference")
        .navigationBarTitleDisplayMode(.inline)
    }
}
