import ProxyModel
import Storage
import SwiftUI
import Viewing

struct FlowDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.inSplitView) private var inSplitView
    let flow: FlowRecord
    /// False when pushed outside the Traffic tab's `path` (from Compose), where ▲/▼ and path edits would hit the wrong stack.
    var inTrafficStack = true
    @AppStorage("detailTab") private var tab = Tab.response
    @AppStorage("groupByEndpoint") private var byEndpoint = false
    @State private var requestBody = BodyLoad.loading
    @State private var responseBody = BodyLoad.loading
    @State private var pushed: FlowRecord?

    @State private var width: CGFloat = 0

    enum Tab: String, CaseIterable {
        case overview = "Overview", request = "Request", response = "Response", exchange = "Request & Response", messages = "Messages"
    }

    /// Wide enough to read the request and the response side by side.
    private var wide: Bool { width >= 640 }

    private var tabs: [Tab] {
        let main: [Tab] = wide ? [.overview, .exchange] : [.overview, .request, .response]
        return flow.isWebSocket ? main + [.messages] : main
    }

    /// The saved tab, mapped to what this width offers: Request or Response becomes Request & Response when wide, and back.
    private var shownTab: Tab {
        if tabs.contains(tab) { return tab }
        if wide, tab == .request || tab == .response { return .exchange }
        return wide ? .exchange : .response
    }

    var body: some View {
        Group {
            if flow.isUndecrypted && flow.state == .failed && shownTab != .request && shownTab != .exchange {
                EncryptedResponseView(host: flow.host, failed: true, error: flow.error)
            } else {
                switch shownTab {
                case .overview: OverviewTab(flow: flow).modifier(ColumnMargins())
                case .request: RequestTab(flow: flow, load: requestBody).modifier(ColumnMargins())
                case .messages: WebSocketMessagesView(flow: flow)
                case .response: response.modifier(ColumnMargins())
                case .exchange:
                    HStack(spacing: 0) {
                        RequestTab(flow: flow, load: requestBody).modifier(ColumnMargins()).modifier(PaneTitle(title: "Request"))
                        Divider().ignoresSafeArea(edges: .bottom)
                        response.modifier(ColumnMargins()).modifier(PaneTitle(title: "Response"))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .modifier(TopBar { SectionTabs(tabs: tabs, selection: Binding(get: { shownTab }, set: { tab = $0 })) })
        .navigationTitle(flow.host)
        .navigationBarTitleDisplayMode(.inline)
        // In a split view the tab bar belongs to every column, so it stays.
        .toolbar(inSplitView ? .automatic : .hidden, for: .tabBar)
        .toolbar {
            // The bar names the request; `navigationTitle` still labels the back button of the next screen.
            ToolbarItem(placement: .principal) { FlowTitle(flow: flow) }
            if inTrafficStack {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    let (newer, older) = neighbours
                    Button { show(newer) } label: { Label("Newer Request", symbol: .keyboardArrowUp) }
                        .disabled(newer == nil)
                        .keyboardShortcut(.upArrow, modifiers: .command)
                    Button { show(older) } label: { Label("Older Request", symbol: .keyboardArrowDown) }
                        .disabled(older == nil)
                        .keyboardShortcut(.downArrow, modifiers: .command)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            RepeatBanner(source: flow.id) { copy in
                if inTrafficStack { model.path.append(.flow(copy)) } else { pushed = copy }
            }
        }
        .bottomBar { FlowBottomBar(flow: flow) }
        .prefersToolbarOverTabBar()
        .navigationDestination(item: $pushed) { FlowDetailView(flow: model.live($0), inTrafficStack: false) }
        // Reload when the exchange finishes or grows, not only when another flow is shown.
        .task(id: BodyKey(id: flow.id, state: flow.state, bytes: flow.requestBytes)) {
            requestBody = .loading
            requestBody = await BodyLoad.load(bodies: model.store?.bodies, flowID: flow.id, side: .request, headers: flow.requestHeaders)
        }
        .task(id: BodyKey(id: flow.id, state: flow.state, bytes: flow.responseBytes)) {
            responseBody = .loading
            responseBody = await BodyLoad.load(bodies: model.store?.bodies, flowID: flow.id, side: .response, headers: flow.responseHeaders)
        }
    }

    @ViewBuilder private var response: some View {
        if flow.isUndecrypted {
            EncryptedResponseView(host: flow.host, failed: flow.state == .failed, error: flow.error)
        } else {
            ResponseTab(flow: flow, load: responseBody)
        }
    }

    /// The requests above and below this one, in the order of the list it was opened from.
    private var neighbours: (FlowRecord?, FlowRecord?) {
        let list: [FlowRecord]
        if let host = model.openHost, byEndpoint {
            list = EndpointGroup.of(model.flows.filter { $0.host == host }).flatMap(\.flows)
        } else {
            list = model.flows
        }
        guard let i = list.firstIndex(where: { $0.id == flow.id }) else { return (nil, nil) }
        return (i > 0 ? list[i - 1] : nil, i + 1 < list.count ? list[i + 1] : nil)
    }

    /// Replaces this screen with a neighbour, only when this screen is the top of the Traffic path.
    private func show(_ other: FlowRecord?) {
        guard let other, case .flow(let current)? = model.path.last, current.id == flow.id else { return }
        model.path[model.path.count - 1] = .flow(other)
    }

    private struct BodyKey: Equatable {
        let id: UUID
        let state: FlowState
        let bytes: Int
    }
}

/// Two lines in the navigation bar: method and path, then status, type, size and time.
private struct FlowTitle: View {
    let flow: FlowRecord

    var body: some View {
        VStack(spacing: 1) {
            (Text(flow.methodText + " ").bold() + Text(flow.graphQL ?? flow.rowPath))
                .font(.mono(.subheadline))
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 4) {
                StatusText(flow: flow)
                Text(details).font(.app(.caption)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// "OK · application/json · 429 B · 348 ms"
    private var details: String {
        var parts: [String] = []
        if let code = flow.statusCode, flow.state == .completed {
            let text = HTTPStatus.text(code)
            if text.count > 4 { parts.append(String(text.dropFirst(4))) }
        }
        if let mime = flow.responseHeaders.value(for: "Content-Type").map({ ContentSniffer.parse($0).mime }) { parts.append(mime) }
        if !flow.isUndecrypted && flow.kind != .dns { parts.append(RequestTab.size(flow.responseBytes)) }
        if let ms = flow.durationMs { parts.append(FlowRow.duration(ms)) }
        return parts.joined(separator: " · ")
    }
}

/// Overview, Request, Response (and Messages for WebSocket) as a segmented control.
private struct SectionTabs: View {
    let tabs: [FlowDetailView.Tab]
    @Binding var selection: FlowDetailView.Tab

    var body: some View {
        Picker("Section", selection: $selection) {
            ForEach(tabs, id: \.self) { Text($0.rawValue) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

/// Names one side of Request & Response above its list.
private struct PaneTitle: ViewModifier {
    let title: LocalizedStringKey

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            Text(title)
                .font(.app(.subheadline, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 6)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

/// Pins a bar under the navigation bar: part of the bar's glass on iOS 26, a bar material with a hairline before.
private struct TopBar<Bar: View>: ViewModifier {
    @ViewBuilder let bar: () -> Bar

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.safeAreaBar(edge: .top, spacing: 0, content: bar)
        } else {
            content.safeAreaInset(edge: .top, spacing: 0) {
                bar().background(.bar).overlay(alignment: .bottom) { Divider() }
            }
        }
    }
}

/// The result of the last Repeat of this flow; tapping it opens the new flow.
private struct RepeatBanner: View {
    @Environment(AppModel.self) private var model
    let source: UUID
    let open: (FlowRecord) -> Void

    var body: some View {
        if let id = model.repeats[source], let copy = model.record(id) {
            HStack(spacing: 8) {
                Button { open(copy) } label: {
                    HStack(spacing: 8) {
                        Image(symbol: .refresh).foregroundStyle(.secondary)
                        if copy.state == .active {
                            Text("Repeating…").foregroundStyle(.secondary)
                        } else {
                            StatusText(flow: copy)
                            if let ms = copy.durationMs { Text(FlowRow.duration(ms)).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Image(symbol: .chevronRight).font(.app(.footnote, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                    .font(.app(.subheadline))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button { model.repeats[source] = nil } label: {
                    Image(symbol: .cancelFill).symbolRenderingMode(.hierarchical).foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal).padding(.vertical, 10)
            .background(.bar)
            .accessibilityElement(children: .contain)
            .sensoryFeedback(trigger: copy.state) { _, state in
                switch state {
                case .completed: .success
                case .failed: .error
                default: nil
                }
            }
        }
    }
}

/// Repeat, Edit, Create Rule, Share and the rest, at the bottom of the detail screen.
private struct FlowBottomBar: View {
    @Environment(AppModel.self) private var model
    let flow: FlowRecord

    var body: some View {
        if model.canResend(flow) {
            Button {
                Task { if let error = await model.repeatFlow(flow) { model.alert = AppAlert(title: "Couldn’t Repeat Request", message: error) } }
            } label: { Label("Repeat", symbol: .refresh) }
            .disabled(!model.tunnel.isRunning)
            .keyboardShortcut("r", modifiers: .command)
            Spacer()
            Button { Task { await model.editAndRepeat(flow) } } label: { Label("Edit and Repeat", symbol: .editSquare) }
                .keyboardShortcut("e", modifiers: .command)
            Spacer()
        }
        if flow.kind != .dns {
            Menu { CreateRuleItems(flow: flow) } label: { Label("Create Rule", symbol: .tune) }
            Spacer()
        }
        if model.canResend(flow) {
            FlowShareMenu(flow: flow)
            Spacer()
        }
        Menu {
            Section { CopyItems(flow: flow) }
            Section { MarkItems(flow: flow) }
        } label: { Label("More", symbol: .moreHoriz) }
    }
}

private struct OverviewTab: View {
    @Environment(AppModel.self) private var model
    let flow: FlowRecord

    var body: some View {
        AppList {
            if let error = flow.error {
                Section("Error") { Text(error).foregroundStyle(.statusError).textSelection(.enabled) }
            }
            if let url = flow.url {
                Section("URL") { Text(url).font(.mono(.subheadline)).textSelection(.enabled) }
            }
            let notes = flow.note?.components(separatedBy: " · ") ?? []
            let applied = notes.filter { RuleBadge.tool(for: $0) != nil }
            if !applied.isEmpty {
                Section("Rules Applied") {
                    ForEach(applied, id: \.self) { Text($0).font(.app(.subheadline)) }
                }
            }
            let other = notes.filter { !applied.contains($0) }
            if !other.isEmpty {
                Section("Note") { ForEach(other, id: \.self) { Text($0).font(.app(.subheadline)) } }
            }
            if let comment = model.marks[flow.id]?.comment, !comment.isEmpty {
                Section("Comment") { Text(comment) }
            }
            Section {
                LabeledContent("Started", value: flow.startedAt.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3))))
                if let v = flow.connectMs {
                    LabeledContent(flow.kind == .https && !flow.isUndecrypted ? "Connect (TCP+TLS)" : "Connect", value: "\(Int(v)) ms")
                }
                if let v = flow.ttfbMs { LabeledContent("Time to First Byte", value: "\(Int(v)) ms") }
                if let ms = flow.durationMs { LabeledContent("Total", value: FlowRow.duration(ms)) }
            } header: { Text("Timing") } footer: {
                // Throttling slows the app's side of the connection; these times are measured on the server's side.
                if flow.note?.contains("Throttled:") == true {
                    SectionFooter { Text("Measured to the server. The added latency and bandwidth limit aren’t included, so the app waited longer.") }
                }
            }
            .monospacedDigit()
            Section("Size") {
                LabeledContent(flow.isUndecrypted ? "Bytes Sent" : "Request Body", value: RequestTab.size(flow.requestBytes))
                LabeledContent(flow.isUndecrypted ? "Bytes Received" : "Response Body", value: RequestTab.size(flow.responseBytes))
            }
            .monospacedDigit()
            Section("Connection") {
                if let version = flow.httpVersion { LabeledContent("Protocol", value: version) }
                LabeledContent("Server", value: "\(flow.ip.isEmpty ? flow.host : flow.ip):\(flow.port)")
            }
        }
    }
}

private struct RequestTab: View {
    @Environment(AppModel.self) private var model
    let flow: FlowRecord
    let load: BodyLoad

    var body: some View {
        AppList {
            let query = FormParser.query(of: flow.url ?? "")
            if !query.isEmpty {
                Section("Query (\(query.count))") { NameValueRows(pairs: query) }
            }
            HeaderSection(headers: flow.requestHeaders)
            if flow.graphQL != nil {
                switch load {
                case .loaded(let body): GraphQLSections(flow: flow, body: body.preview.decoded.data)
                case .empty: GraphQLSections(flow: flow, body: Data())
                case .loading: EmptyView()
                }
            }
            if !flow.isUndecrypted && flow.kind != .dns {
                BodySection(load: load)
            }
        }
    }

    static func size(_ n: Int) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: Int64(n))
    }
}

private struct ResponseTab: View {
    let flow: FlowRecord
    let load: BodyLoad

    var body: some View {
        AppList {
            HeaderSection(headers: flow.responseHeaders)
            if flow.kind != .dns {
                BodySection(load: load)
            }
        }
    }
}

/// Headers as rows, or as raw `Name: value` text.
private struct HeaderSection: View {
    let headers: [HeaderField]
    @State private var raw = false

    var body: some View {
        Section {
            if headers.isEmpty {
                Text("None").foregroundStyle(.secondary)
            } else if raw {
                Text(rawText).font(.mono(.caption)).textSelection(.enabled)
            } else {
                ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                    VStack(alignment: .leading) {
                        Text(header.name).font(.app(.caption, weight: .bold))
                        Text(header.value).font(.mono(.caption))
                    }
                    .accessibilityElement(children: .combine)
                    .contextMenu {
                        Button("Copy Value") { UIPasteboard.general.string = header.value }
                        Button("Copy Line") { UIPasteboard.general.string = "\(header.name): \(header.value)" }
                    }
                }
            }
        } header: {
            HStack {
                Text("Headers (\(headers.count))")
                Spacer()
                if !headers.isEmpty {
                    Menu {
                        Button(raw ? "View as Table" : "View as Raw") { raw.toggle() }
                        Button("Copy All") { UIPasteboard.general.string = rawText }
                    } label: { Image(symbol: .moreHoriz) }
                    .headerControl()
                    .accessibilityLabel("Header actions")
                }
            }
        }
    }

    private var rawText: String { headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n") }
}

/// Explains an undecrypted or failed HTTPS connection and offers to change decryption for its host.
private struct EncryptedResponseView: View {
    @Environment(AppModel.self) private var model
    let host: String
    let failed: Bool
    var error: String?

    /// Who broke off the handshake: the server, the app refusing the certificate, or the app just leaving.
    private enum Failure { case server, rejected, closed }

    private var failure: Failure? {
        guard failed else { return nil }
        if error?.hasPrefix(FlowRecord.upstreamTLSPrefix) == true { return .server }
        if error?.hasPrefix(FlowRecord.clientRejectedPrefix) == true { return .rejected }
        return .closed
    }

    var body: some View {
        let on = model.isDecrypting(host)
        ContentUnavailableView {
            switch failure {
            case .server: Label(emptyState: "Couldn’t Connect to Server", symbol: .noEncryption)
            case .rejected, .closed: Label(emptyState: "TLS Handshake Failed", symbol: .noEncryption)
            case nil: Label(emptyState: "Not Decrypted", symbol: .lockFill)
            }
        } description: {
            Group {
                switch failure {
                case .server:
                    Text("Passage couldn’t finish a secure connection to \(host), so the app’s request never reached it. The server may be down or unreachable from this network.")
                case .rejected:
                    Text("The app refused the Passage certificate for \(host). It probably pins its certificate, so this host can’t be decrypted.")
                case .closed:
                    Text("The app closed the connection to \(host) during the TLS handshake. If this keeps happening, the app may pin its certificate.")
                case nil:
                    Text(on ? "Decryption is on for \(host). Repeat the action in the app to record its requests."
                            : "Requests to \(host) aren’t decrypted. Tap Decrypt This Host, then repeat the action in the app.")
                }
            }
            .font(.app(.body))
        } actions: {
            if failure == .rejected || failure == .closed {
                Button("Don’t Decrypt This Host") { model.stopDecrypting(host) }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
            } else if failure == nil && !on {
                Button("Decrypt This Host") { model.setSSLProxying(host, true) }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
            }
            if model.caTrusted != true {
                Button("Install Certificate…") { model.showCertificateGuide = true }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

struct NameValueRows: View {
    let pairs: [(name: String, value: String)]

    var body: some View {
        ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
            VStack(alignment: .leading) {
                Text(pair.name).font(.app(.caption, weight: .bold))
                Text(pair.value).font(.mono(.caption)).textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
