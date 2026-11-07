import ProxyModel
import Storage
import SwiftUI
import UniformTypeIdentifiers
import Viewing

/// Screens pushed in the Compose tab.
/// The Compose tab: the draft, recent requests and imported APIs; each opens the editor.
struct ComposeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.inSplitView) private var inSplitView
    @State private var recent: [ComposeHistoryItem] = []
    @State private var collections: [APICollection] = []
    @State private var showImporter = false
    @State private var importError: String?
    /// A request waiting to replace a draft that has content, until the user confirms.
    @State private var pending: ComposeDraft?
    @State private var search = ""
    /// Collections opened in place in a split view's sidebar.
    @State private var expanded: Set<UUID> = []

    private func matches(_ texts: String?...) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || texts.contains { $0?.localizedCaseInsensitiveContains(query) == true }
    }

    var body: some View {
        @Bindable var model = model
        AppList {
            // A split view shows the draft in its editor column.
            if model.composeDraft != ComposeDraft() && !inSplitView {
                Section("Draft") {
                    NavigationLink(value: ComposeRoute.editor) { RequestLine(draft: model.composeDraft) }
                        .swipeActions {
                            SwipeAction("Discard", symbol: .delete, color: .statusError, role: .destructive) { model.composeDraft = ComposeDraft() }
                        }
                }
            }
            let recent = recent.filter { matches($0.request.method, $0.request.url) }
            if !recent.isEmpty {
                Section("Recent") {
                    ForEach(recent.prefix(search.isEmpty ? 5 : 50)) { item in
                        Button { open(ComposeDraft(item.request)) } label: {
                            PushRow {
                                RequestLine(method: item.request.method, url: item.request.url, detail: item.createdAt.formatted(.dateTime.day().month().hour().minute()))
                            }
                        }
                        .tint(.primary)
                        .deleteSwipe { try? model.store?.deleteComposeHistory(id: item.id); refresh() }
                    }
                    .onDelete { offsets in
                        for i in offsets { try? model.store?.deleteComposeHistory(id: recent[i].id) }
                        refresh()
                    }
                    NavigationLink("Show All History", value: ComposeRoute.history)
                }
            }
            Section {
                ForEach(collections) { collection in
                    if inSplitView {
                        collectionGroup(collection)
                    } else {
                        NavigationLink(value: ComposeRoute.collection(collection.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(collection.title + (collection.version.map { " \($0)" } ?? ""))
                                Text("^[\(collection.requests.count) request](inflect: true) · \(collection.baseURL)").font(.app(.caption)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .deleteSwipe { model.deleteAPICollection(collection.id); refresh() }
                    }
                }
                .onDelete { offsets in
                    for i in offsets { model.deleteAPICollection(collections[i].id) }
                    refresh()
                }
                Button("Import OpenAPI…") { showImporter = true }
            } header: { Text("APIs") } footer: {
                SectionFooter {
                    if collections.isEmpty { Text("Import an OpenAPI 3 or Swagger 2 file in JSON or YAML.") }
                }
            }
        }
        .navigationTitle("Compose")
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search requests")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { open(ComposeDraft()) } label: { Label("New Request", symbol: inSplitView ? .editSquare : .add) }
            }
        }
        .confirmationDialog("Replace the current draft?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible) {
            Button("Discard Draft", role: .destructive) {
                if let pending { apply(pending) }
            }
        }
        .navigationDestination(for: ComposeRoute.self) { route in
            switch route {
            case .editor: ComposeEditor(draft: $model.composeDraft)
            case .history: ComposeHistoryView { open(ComposeDraft($0)) }
            case .collection(let id):
                if let collection = collections.first(where: { $0.id == id }) {
                    APICollectionDetail(collection: collection) { open(ComposeDraft($0.request)) }
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json, .yaml, .plainText]) { result in
            guard case .success(let url) = result else { return }
            Task {
                importError = await model.importOpenAPI(from: url)
                refresh()
            }
        }
        .alert("Couldn’t Import API", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(importError ?? "") }
        .onAppear(perform: refresh)
    }

    /// A collection that opens in place to its endpoints, each of which opens in the editor beside the list.
    private func collectionGroup(_ collection: APICollection) -> some View {
        let requests = collection.requests.filter { matches($0.name, $0.summary, $0.request.url, $0.request.method) }
        let open = Binding(get: { expanded.contains(collection.id) || !search.isEmpty },
                           set: { if $0 { expanded.insert(collection.id) } else { expanded.remove(collection.id) } })
        return DisclosureGroup(isExpanded: open) {
            ForEach(requests) { request in
                Button { self.open(ComposeDraft(request.request)) } label: {
                    RequestLine(method: request.request.method, url: request.request.url, detail: request.summary ?? request.name)
                }
                .tint(.primary)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(collection.title + (collection.version.map { " \($0)" } ?? ""))
                Text("^[\(collection.requests.count) request](inflect: true)").font(.app(.caption)).foregroundStyle(.secondary)
            }
        }
        .deleteSwipe { model.deleteAPICollection(collection.id); refresh() }
    }

    /// Opens `draft` in the editor; asks first when it would replace a draft that has content.
    private func open(_ draft: ComposeDraft) {
        if model.composeDraft.isBlank { apply(draft) } else { pending = draft }
    }

    private func apply(_ draft: ComposeDraft) {
        pending = nil
        model.composeDraft = draft
        model.composeOpens += 1
        if !inSplitView { model.composePath.append(.editor) }
    }

    private func refresh() {
        recent = (try? model.store?.composeHistory()) ?? []
        collections = model.apiCollections()
    }
}

/// Method and URL in monospace, with a detail line.
private struct RequestLine: View {
    let method: String
    let url: String
    let detail: String

    init(method: String, url: String, detail: String) {
        self.method = method
        self.url = url
        self.detail = detail
    }

    init(draft: ComposeDraft) {
        let headers = draft.headers.filter(\.enabled).count
        let body = draft.binaryBody?.count ?? draft.bodyText.utf8.count
        self.init(method: draft.method, url: draft.url.isEmpty ? "No URL" : draft.url,
                  detail: "\(headers) header\(headers == 1 ? "" : "s") · \(RequestTabSize.text(body)) body")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            (Text(method + " ").bold() + Text(url)).font(.mono(.subheadline)).lineLimit(1).truncationMode(.middle)
            Text(detail).font(.app(.caption)).foregroundStyle(.secondary)
        }
    }
}

/// Edit a request and send it; the response shows up in place.
struct ComposeEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.inSplitView) private var inSplitView
    @Binding var draft: ComposeDraft
    @State private var sending = false
    @State private var sentID: UUID?
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var confirmNew = false

    @State private var width: CGFloat = 0

    /// After Clear Traffic the sent request is gone, so its response goes too.
    private var sent: FlowRecord? { sentID.flatMap { model.record($0) } }

    var body: some View {
        Group {
            // Wide enough for the response beside the request instead of under it.
            if width >= 640, let sent {
                HStack(spacing: 0) {
                    requestForm(response: nil)
                    Divider().ignoresSafeArea(edges: .bottom)
                    AppForm { ComposeResponseSection(flow: sent) }
                }
            } else if inSplitView {
                requestForm(response: sent).readableWidth()
            } else {
                requestForm(response: sent)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .scrollDismissesKeyboard(.interactively)
        .keyboardDoneButton()
        .navigationTitle("Request")
        .navigationBarTitleDisplayMode(.inline)
        .prefersToolbarOverTabBar()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if sending {
                    ProgressView()
                } else {
                    Button { Task { await send() } } label: { Label("Send", symbol: .sendFill) }
                        .disabled(!model.tunnel.isRunning || draft.urlProblem != nil)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { model.codeSheet = CodeSheetRequest(request: draft.request) } label: {
                        Text("Copy as cURL, Swift…")
                    }
                    .disabled(draft.urlProblem != nil)
                    Button(role: .destructive) { if draft.isBlank { clear() } else { confirmNew = true } } label: {
                        Text("New Request")
                    }
                } label: { Label("More", symbol: .moreHoriz) }
                .confirmationDialog("Discard this request?", isPresented: $confirmNew, titleVisibility: .visible) {
                    Button("Discard Request", role: .destructive, action: clear)
                }
            }
        }
    }

    private func requestForm(response: FlowRecord?) -> some View {
        ScrollViewReader { proxy in
            requestRows(response: response)
                // The response lands below the request, so bring it up on send and again once it arrives.
                .onChange(of: response.map { "\($0.id) \($0.state)" }) { _, key in
                    guard key != nil else { return }
                    withAnimation { proxy.scrollTo(ComposeResponseSection.anchor, anchor: .top) }
                }
        }
    }

    private func requestRows(response: FlowRecord?) -> some View {
        AppForm {
            Section {
                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                                                          : AnyLayout(HStackLayout(spacing: 8))
                layout {
                    Picker("Method", selection: $draft.method) {
                        ForEach(ComposeDraft.methods, id: \.self) { Text($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    TextField("URL", text: $draft.url, prompt: Text(verbatim: "https://api.example.com/path"), axis: .vertical)
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

            ComposeHeadersSection(draft: $draft)
            ComposeBodySection(draft: $draft)

            if let response { ComposeResponseSection(flow: response) }
        }
    }

    private func clear() {
        draft = ComposeDraft()
        sentID = nil
    }

    private func send() async {
        sending = true
        switch await model.dispatch(draft.request) {
        case .success(let flow): sentID = flow.id
        case .failure(let error): model.alert = AppAlert(title: "Couldn’t Send Request", message: error.message)
        }
        sending = false
    }
}

/// The request's headers, each with a switch to leave it out without deleting it.
struct ComposeHeadersSection: View {
    @Binding var draft: ComposeDraft
    /// Name and value side by side on one line, as a table, when the column has room.
    var wide = false

    var body: some View {
        Section {
            ForEach($draft.headers) { $header in
                HStack(alignment: wide ? .center : .top, spacing: 2) {
                    Button { header.enabled.toggle() } label: {
                        Image(symbol: header.enabled ? .checkCircleFill : .circle)
                            .foregroundStyle(header.enabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            .frame(minWidth: wide ? 32 : 44, minHeight: wide ? 32 : 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(header.name.isEmpty ? "Header" : header.name)
                    .accessibilityValue(header.enabled ? "On" : "Off")
                    .accessibilityAddTraits(.isToggle)
                    Group {
                        if wide {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                TextField("Name", text: $header.name).font(.app(.caption, weight: .bold))
                                    .frame(width: 180, alignment: .leading)
                                TextField("Value", text: $header.value, axis: .vertical).font(.mono(.caption))
                            }
                        } else {
                            VStack(spacing: 4) {
                                TextField("Name", text: $header.name).font(.app(.caption, weight: .bold))
                                TextField("Value", text: $header.value, axis: .vertical).font(.mono(.caption))
                            }
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .opacity(header.enabled ? 1 : 0.4)
                }
                .listRowInsets(wide ? EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 16) : nil)
                .deleteSwipe { draft.headers.removeAll { $0.id == header.id } }
            }
            .onDelete { draft.headers.remove(atOffsets: $0) }
            Button("Add Header") { draft.headers.append(EditableHeader(name: "", value: "")) }
        } header: {
            Text("Headers (\(draft.headers.count))")
        } footer: {
        SectionFooter {
                Text("Host and Content-Length are added when missing. Everything else is sent exactly as written.")
        }
    }
    }
}

/// The request body as text, or the size of a binary one, with JSON formatting.
struct ComposeBodySection: View {
    @Binding var draft: ComposeDraft
    @State private var notJSON = false

    var body: some View {
        Section {
            if let binary = draft.binaryBody {
                LabeledContent("Binary Body", value: RequestTabSize.text(binary.count))
                Button("Remove Body", role: .destructive) { draft.binaryBody = nil }
            } else {
                TextEditor(text: $draft.bodyText)
                    .font(.mono(.caption))
                    .frame(minHeight: 140)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        } header: {
            HStack {
                Text("Body")
                Spacer()
                if draft.binaryBody == nil {
                    Menu {
                        Button("Pretty-Print JSON") { reformat(pretty: true) }
                        Button("Minify JSON") { reformat(pretty: false) }
                        Button("Clear Body", role: .destructive) { draft.bodyText = "" }
                    } label: { Text("Format").font(.app(.caption)).textCase(nil) }
                    .headerControl()
                }
            }
        } footer: {
        SectionFooter {
                if notJSON { Text("The body isn’t valid JSON.").foregroundStyle(.statusError) }
        }
    }
    .sensoryFeedback(.error, trigger: notJSON) { _, failed in failed }
    }

    private func reformat(pretty: Bool) {
        guard let data = draft.bodyText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let out = try? JSONSerialization.data(withJSONObject: object, options: pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.withoutEscapingSlashes])
        else { notJSON = true; return }
        notJSON = false
        draft.bodyText = String(decoding: out, as: UTF8.self)
    }
}

/// The answer to a request sent from the editor, refreshed as it arrives.
private struct ComposeResponseSection: View {
    /// Scroll target for the first row, so Send can bring the response into view.
    static let anchor = "compose.response"
    @Environment(AppModel.self) private var model
    let flow: FlowRecord
    @State private var preview: String?

    var body: some View {
        Section("Response") {
            if flow.host.isEmpty || flow.state == .active {
                HStack { ProgressView(); Text("Waiting for the response…").foregroundStyle(.secondary) }
                    .id(Self.anchor)
            } else {
                HStack(spacing: 6) {
                    StatusText(flow: flow)
                    Text([flow.statusCode.map(HTTPStatus.phrase) ?? flow.error, RequestTabSize.text(flow.responseBytes),
                          flow.durationMs.map(FlowRow.duration)].compactMap { $0 }.joined(separator: " · "))
                        .font(.app(.caption)).foregroundStyle(.secondary)
                }
                .id(Self.anchor)
                if let preview, !preview.isEmpty {
                    Text(preview).font(.mono(.caption)).lineLimit(10).textSelection(.enabled)
                }
                NavigationLink { FlowDetailView(flow: model.live(flow), inTrafficStack: false) } label: { Text("Show Details") }
            }
        }
        .task(id: flow.state) {
            guard flow.state != .active, let bodies = model.store?.bodies else { return }
            let id = flow.id
            let headers = flow.responseHeaders
            preview = await Task.detached {
                guard let prefix = bodies.readPrefix(flowID: id, side: .response, maxBytes: 16 * 1024) else { return nil }
                let p = BodyPreview(raw: prefix.data, storedSize: prefix.totalSize, headers: headers)
                return String(p.fullText().prefix(2000))
            }.value
        }
    }
}

/// Every request sent from Compose; tapping one opens it in the editor.
struct ComposeHistoryView: View {
    @Environment(AppModel.self) private var model
    let pick: (ComposedRequest) -> Void
    @State private var items: [ComposeHistoryItem] = []
    @State private var search = ""
    @State private var confirmClear = false

    private var shown: [ComposeHistoryItem] {
        search.isEmpty ? items : items.filter {
            $0.request.url.localizedCaseInsensitiveContains(search) || $0.request.method.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        AppList {
            ForEach(shown) { item in
                Button { pick(item.request) } label: {
                    PushRow {
                        VStack(alignment: .leading, spacing: 2) {
                            RequestLine(method: item.request.method, url: item.request.url,
                                        detail: item.createdAt.formatted(.dateTime.day().month().hour().minute()))
                            if item.bodyDropped { Text("The body is over 1 MB, so it wasn’t saved.").font(.app(.caption2)).foregroundStyle(.statusWarning) }
                        }
                    }
                }
                .tint(.primary)
                .deleteSwipe {
                    try? model.store?.deleteComposeHistory(id: item.id)
                    items.removeAll { $0.id == item.id }
                }
            }
            .onDelete { offsets in
                let ids = Set(offsets.map { shown[$0].id })
                for id in ids { try? model.store?.deleteComposeHistory(id: id) }
                items.removeAll { ids.contains($0.id) }
            }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView("No History", symbol: .schedule, description: Text("Requests you send appear here."))
            } else if shown.isEmpty {
                ContentUnavailableView(searching: search)
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "URL or method")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear") { confirmClear = true }.disabled(items.isEmpty)
            }
        }
        .confirmationDialog("Clear all history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) {
                for item in items { try? model.store?.deleteComposeHistory(id: item.id) }
                items = []
            }
        }
        .task { items = (try? model.store?.composeHistory()) ?? [] }
    }
}

/// Edit and Repeat from Traffic: its own copy of the draft, pushed over the flow it came from.
struct RouteComposeEditor: View {
    @State var draft: ComposeDraft

    var body: some View { ComposeEditor(draft: $draft) }
}

/// A button row that opens another screen, with the chevron a NavigationLink row would show.
struct PushRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack {
            content
            Spacer(minLength: 8)
            Image(symbol: .chevronRight)
                .font(.app(.footnote, weight: .semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }
}

/// The Compose tab: a stack in compact width; in regular width the list beside an editor that is always open.
struct ComposeTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var model = model
        Group {
            if sizeClass != .regular {
                NavigationStack(path: $model.composePath) { ComposeView() }
            } else {
                NavigationSplitView(columnVisibility: $columns) {
                    NavigationStack(path: listPath) { ComposeView() }
                        .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 420)
                        .toolbar(removing: .sidebarToggle)
                } detail: {
                    // A request picked from the list starts a fresh editor, without the last response.
                    NavigationStack { ComposeWideEditor(draft: $model.composeDraft) }
                        .id(model.composeOpens)
                }
                .navigationSplitViewStyle(.balanced)
                .environment(\.inSplitView, true)
            }
        }
    }

    /// History and API screens push in the list column; the editor has its own column.
    private var listPath: Binding<[ComposeRoute]> {
        Binding(get: { model.composePath.filter { $0 != .editor } }, set: { model.composePath = $0 })
    }
}
