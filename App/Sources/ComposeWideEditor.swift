import ProxyModel
import SwiftUI
import Viewing

/// The request editor in a wide detail column: method and URL on top, one of Params, Headers or Body below them,
/// and the response in a lower pane that a handle resizes, like a request tool on a computer.
struct ComposeWideEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: ComposeDraft
    @State private var part = Part.headers
    @State private var sending = false
    @State private var sentID: UUID?
    @State private var showsResponse = true
    /// The request's share of the height when the response pane shows.
    @State private var split: CGFloat = 0.6
    @State private var dragStart: CGFloat?
    @State private var confirmNew = false

    private enum Part: String, CaseIterable { case params = "Params", headers = "Headers", body = "Body" }

    /// After Clear Traffic the sent request is gone, so its response goes too.
    private var sent: FlowRecord? { sentID.flatMap { model.record($0) } }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                request
                    .frame(height: sent != nil && showsResponse ? geo.size.height * split : nil)
                if let sent, showsResponse {
                    handle(height: geo.size.height)
                    ComposeResponsePane(flow: sent)
                }
            }
        }
        .themedBackground()
        #if DEBUG
        // `-mockCompose YES` with `-mockTraffic -mockOpen <host>` loads that host's newest request and its response,
        // for screenshots of the response pane on a simulator, which cannot send.
        .task {
            guard UserDefaults.standard.bool(forKey: "mockCompose"), sentID == nil else { return }
            for _ in 0..<30 {
                if let flow = model.flows.first(where: { $0.statusCode != nil }) {
                    draft = ComposeDraft(ComposedRequest(flow: flow, body: nil))
                    sentID = flow.id
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        #endif
        .scrollDismissesKeyboard(.interactively)
        .keyboardDoneButton()
        .navigationTitle("Request")
        .navigationBarTitleDisplayMode(.inline)
        .prefersToolbarOverTabBar()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showsResponse.toggle() } label: { Label(showsResponse ? "Hide Response" : "Show Response", symbol: .panelBottom) }
                    .disabled(sent == nil)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { model.codeSheet = CodeSheetRequest(request: draft.request) } label: { Text("Copy as cURL, Swift…") }
                        .disabled(draft.urlProblem != nil)
                    Button(role: .destructive) { if draft.isBlank { clear() } else { confirmNew = true } } label: { Text("New Request") }
                } label: { Label("More", symbol: .moreHoriz) }
                .confirmationDialog("Discard this request?", isPresented: $confirmNew, titleVisibility: .visible) {
                    Button("Discard Request", role: .destructive, action: clear)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                if sending {
                    ProgressView()
                } else {
                    Button { Task { await send() } } label: { Label("Send", symbol: .sendFill).labelStyle(.titleAndIcon) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.tunnel.isRunning || draft.urlProblem != nil)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
    }

    private var request: some View {
        AppForm {
            Section {
                HStack(spacing: 8) {
                    Picker("Method", selection: $draft.method) {
                        ForEach(ComposeDraft.methods, id: \.self) { Text($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    TextField("URL", text: $draft.url, prompt: Text(verbatim: "https://api.example.com/path"))
                        .font(.mono(.subheadline))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            } footer: {
                SectionFooter {
                    if let problem = draft.urlProblem, !draft.url.isEmpty {
                        Text(problem).foregroundStyle(.statusError)
                    } else if !model.tunnel.isRunning {
                        Text("The proxy is off, so requests can’t be sent.")
                    }
                }
            }

            Section {
                Picker("Part", selection: $part) {
                    ForEach(Part.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            switch part {
            case .params: ComposeParamsSection(url: $draft.url)
            case .headers: ComposeHeadersSection(draft: $draft, wide: true)
            case .body: ComposeBodySection(draft: $draft)
            }
        }
        .environment(\.defaultMinListRowHeight, 36)
    }

    /// Drag to give the request or the response more room.
    private func handle(height: CGFloat) -> some View {
        Capsule()
            .fill(.quaternary)
            .frame(width: 40, height: 5)
            .frame(maxWidth: .infinity, minHeight: 20)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let start = dragStart ?? split
                    dragStart = start
                    split = min(max(start + value.translation.height / max(height, 1), 0.25), 0.8)
                }
                .onEnded { _ in dragStart = nil })
            .accessibilityElement()
            .accessibilityLabel("Resize Response")
            .accessibilityValue("\(Int((1 - split) * 100)) percent")
            .accessibilityAdjustableAction { direction in
                split = min(max(split + (direction == .increment ? -0.1 : 0.1), 0.25), 0.8)
            }
    }

    private func clear() {
        draft = ComposeDraft()
        sentID = nil
    }

    private func send() async {
        sending = true
        switch await model.dispatch(draft.request) {
        case .success(let flow):
            sentID = flow.id
            showsResponse = true
        case .failure(let error): model.alert = AppAlert(title: "Couldn’t Send Request", message: error.message)
        }
        sending = false
    }
}

/// The URL's query items as rows; editing them rewrites the URL.
struct ComposeParamsSection: View {
    @Binding var url: String

    private var items: [URLQueryItem] { URLComponents(string: url)?.queryItems ?? [] }

    var body: some View {
        let items = items
        Section {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(spacing: 8) {
                    TextField("Name", text: field(index, value: false)).font(.app(.caption, weight: .bold))
                    TextField("Value", text: field(index, value: true)).font(.mono(.caption))
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .deleteSwipe { update { $0.remove(at: index) } }
            }
            Button("Add Parameter") { update { $0.append(URLQueryItem(name: "name", value: "")) } }
                .disabled(URLComponents(string: url) == nil)
        } header: {
            Text("Params (\(items.count))")
        } footer: {
            SectionFooter {
                Text("Query parameters of the URL above.")
            }
        }
    }

    /// The name, or with `value` the value, of the item at `index`.
    private func field(_ index: Int, value: Bool) -> Binding<String> {
        Binding(get: {
            guard index < items.count else { return "" }
            return value ? items[index].value ?? "" : items[index].name
        }, set: { text in
            update { list in
                guard index < list.count else { return }
                list[index] = value ? URLQueryItem(name: list[index].name, value: text) : URLQueryItem(name: text, value: list[index].value)
            }
        })
    }

    private func update(_ change: (inout [URLQueryItem]) -> Void) {
        guard var components = URLComponents(string: url) else { return }
        var list = components.queryItems ?? []
        change(&list)
        components.queryItems = list.isEmpty ? nil : list
        if let string = components.string { url = string }
    }
}

/// The response to a request sent from the wide editor: status, then its body or headers.
struct ComposeResponsePane: View {
    @Environment(AppModel.self) private var model
    let flow: FlowRecord
    @State private var showsHeaders = false
    @State private var text: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if flow.host.isEmpty || flow.state == .active {
                    ProgressView()
                    Text("Waiting for the response…").foregroundStyle(.secondary)
                } else {
                    StatusText(flow: flow)
                    Text([flow.statusCode.map(HTTPStatus.phrase) ?? flow.error, RequestTabSize.text(flow.responseBytes),
                          flow.durationMs.map(FlowRow.duration)].compactMap { $0 }.joined(separator: " · "))
                        .font(.app(.footnote)).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Show", selection: $showsHeaders) {
                    Text("Body").tag(false)
                    Text("Headers").tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                NavigationLink { FlowDetailView(flow: model.live(flow), inTrafficStack: false) } label: { Text("Details") }
            }
            .padding(.horizontal, 20)

            Group {
                if showsHeaders {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(flow.responseHeaders.enumerated()), id: \.offset) { _, field in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(field.name).font(.app(.caption, weight: .bold))
                                    Text(field.value).font(.mono(.caption)).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                    }
                } else {
                    ScrollView {
                        Text(text ?? "")
                            .font(.mono(.caption))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                    .overlay {
                        if text?.isEmpty ?? true, flow.state != .active { Text("No body").foregroundStyle(.secondary) }
                    }
                }
            }
            .background(Color.card, in: .rect(cornerRadius: Theme.current.cornerRadius))
            .padding([.horizontal, .bottom], 20)
        }
        .task(id: flow.state) {
            guard flow.state != .active, let bodies = model.store?.bodies else { return }
            let id = flow.id
            let headers = flow.responseHeaders
            text = await Task.detached {
                guard let prefix = bodies.readPrefix(flowID: id, side: .response, maxBytes: 256 * 1024) else { return nil }
                return BodyPreview(raw: prefix.data, storedSize: prefix.totalSize, headers: headers).fullText()
            }.value
        }
    }
}
