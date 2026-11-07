import ProxyModel
import Storage
import SwiftUI
import TipKit

struct FlowListView: View {
    @Environment(AppModel.self) private var model
    @State private var showFilter = false
    @State private var confirmClear = false
    @State private var showSessions = false
    @State private var showImporter = false
    @State private var savingSession = false
    @State private var editMode = EditMode.inactive
    @State private var selection = Set<UUID>()
    @State private var barsVertical = false
    @Environment(\.inSplitView) private var inSplitView

    /// The system title and subtitle fit a narrow column and a vertical bar, where the two-line custom title does not.
    private var systemTitle: Bool {
        if #available(iOS 26, *) { inSplitView || barsVertical } else { false }
    }

    var body: some View {
        @Bindable var model = model
        // A selection binding outside Select mode makes iOS 26 push a tapped link twice.
        AppList(plain: true, selection: editMode.isEditing ? $selection : nil) {
            StatusBanner()
            SessionRow()
            if model.mode == .domain {
                if !model.domains.isEmpty { TipView(DecryptHostTip()).tipBackground(Color.card).listRowSeparator(.hidden) }
                DomainRows()
            } else {
                if !model.flows.isEmpty { TipView(RequestActionsTip()).tipBackground(Color.card).listRowSeparator(.hidden) }
                Section {
                    ForEach(model.flows) { flow in
                        RouteLink(.flow(flow)) { FlowRow(flow: flow, mark: model.marks[flow.id]) }
                            .modifier(FlowSwipeActions(flow: flow))
                    }
                }
            }
            HiddenAppleRow()
        }
        .listStyle(.plain)
        .overlay {
            EmptyListOverlay(empty: model.mode == .domain ? model.domains.isEmpty : model.flows.isEmpty)
        }
        .flowSearch(prompt: "Host, path or GraphQL operation", regexPrompt: "Regex on host, path or operation")
        .navigationTitle("Traffic")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(NavigationSubtitle(text: systemTitle && !editMode.isEditing ? model.captureSubtitle : nil))
        .modifier(VerticalBarsReader(isVertical: $barsVertical))
        .toolbar {
            if !editMode.isEditing {
                if !systemTitle {
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 0) {
                            Text("Traffic").font(.app(.headline))
                            Text(model.captureSubtitle).font(.app(.caption2)).foregroundStyle(.secondary)
                        }
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .accessibilityElement(children: .combine)
                    }
                }
                ToolbarItem(placement: .topBarLeading) { CaptureButton() }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    FilterMenu(showFilter: $showFilter, grouping: .traffic)
                    TrafficArchiveMenu(showSessions: $showSessions, showImporter: $showImporter,
                                       savingSession: $savingSession, confirmClear: $confirmClear,
                                       select: model.mode == .timeline && !model.flows.isEmpty ? { editMode = .active } : nil)
                }
            }
        }
        .modifier(FlowSelection(editMode: $editMode, selection: $selection, flows: model.flows, title: "Passage",
                                isFrontmost: model.path.isEmpty))
        .confirmationDialog("Clear all recorded traffic?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear Traffic", role: .destructive) { Task { await model.clearSession() } }
        }
        .sheet(isPresented: $showFilter) { FilterSheet() }
        .sheet(isPresented: $showSessions) { SessionsView() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.har, .charlesSession, .json]) { result in
            if case .success(let url) = result { Task { await model.importArchive(from: url) } }
        }
        .modifier(SaveSessionAlert(isPresented: $savingSession))
    }
}

/// Says that the list shows an opened session rather than live traffic, with the way back.
struct SessionRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let session = model.filter.session {
            HStack {
                Label {
                    Text("Viewing \(session)").lineLimit(1).truncationMode(.middle)
                } icon: {
                    Image(symbol: .schedule)
                }
                .font(.app(.footnote)).foregroundStyle(.secondary)
                Spacer()
                Button("Show Live Traffic") { model.filter.session = nil }
                    .font(.app(.footnote))
                    .buttonStyle(.borderless)
                    .headerControl()
            }
            .listRowSeparator(.hidden)
        }
    }
}

/// Says how many requests the Apple filter hides, with a way to show them.
struct HiddenAppleRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let n = model.hiddenAppleCount
        if n > 0 {
            HStack {
                Text("\(n) request\(n == 1 ? "" : "s") to Apple services hidden")
                    .font(.app(.footnote)).foregroundStyle(.secondary)
                Spacer()
                Button("Show") { model.filter.hideAppleServices = false }
                    .font(.app(.footnote))
                    .buttonStyle(.borderless)
                    .headerControl()
            }
            .listRowSeparator(.hidden)
        }
    }
}

/// Starts or stops capturing: play while stopped, pause while running.
struct CaptureButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.tunnel.isBusy {
            ProgressView()
                .accessibilityLabel(model.tunnel.isRunning ? "Stopping Proxy" : "Starting Proxy")
        } else {
            Button {
                Task { await model.toggleTunnel() }
            } label: {
                Label(model.tunnel.isRunning ? "Stop Proxy" : "Start Proxy", symbol: symbol)
            }
            .accessibilityValue(model.tunnel.isRunning ? "On" : "Off")
        }
    }

    /// iOS 26 draws the bar button in a glass circle, so the glyph drops its own.
    private var symbol: AppSymbol {
        if #available(iOS 26, *) { return model.tunnel.isRunning ? .pause : .playArrow }
        return model.tunnel.isRunning ? .pauseCircle : .playCircle
    }
}

/// Group by, which flow kinds to show, and the full filter sheet.
struct FilterMenu: View {
    @Environment(AppModel.self) private var model
    @Binding var showFilter: Bool
    let grouping: Grouping
    @AppStorage("groupByEndpoint") private var byEndpoint = false

    /// Which "Group by" choices the screen offers.
    enum Grouping { case traffic, domain }

    var body: some View {
        @Bindable var model = model
        Menu {
            Section("Group By") {
                switch grouping {
                case .traffic:
                    Picker("Group By", selection: $model.mode) {
                        Text("Host").tag(ListMode.domain)
                        Text("None").tag(ListMode.timeline)
                    }
                case .domain:
                    Picker("Group By", selection: $byEndpoint) {
                        Text("Endpoint").tag(true)
                        Text("None").tag(false)
                    }
                }
            }
            Section("Show") {
                kindToggle("HTTP", .http)
                kindToggle("HTTPS", .https)
                kindToggle("DNS", .dns)
                kindToggle("Other TCP", .raw)
                Toggle("Pinned Hosts", isOn: $model.filter.showPinned)
                Toggle("Apple Services", isOn: Binding(get: { !model.filter.hideAppleServices },
                                                              set: { model.filter.hideAppleServices = !$0 }))
            }
            Section {
                Button("More Filters…") { showFilter = true }
                Button("Reset Filters") { model.filter = FlowFilter() }
                    .disabled(model.filter.isDefault && !model.filter.isRegex)
            }
        } label: {
            Label("Filter", symbol: model.filter.isDefault ? .filterList : .filterAltFill)
        }
        .accessibilityValue(model.filter.isDefault ? "Off" : "On")
    }

    private func kindToggle(_ title: String, _ kind: FlowKind) -> some View {
        let chip = FilterChip.kind(kind)
        return Toggle(title, isOn: Binding(get: { chip.isOn(in: model.filter) }, set: { _ in chip.toggle(in: &model.filter) }))
    }
}

/// One domain's requests, newest first, in a section per endpoint. Rows leave out the host, which is the title.
struct DomainFlowsView: View {
    @Environment(AppModel.self) private var model
    let host: String
    @State private var showFilter = false
    @AppStorage("groupByEndpoint") private var byEndpoint = false
    @State private var editMode = EditMode.inactive
    @State private var selection = Set<UUID>()

    var body: some View {
        // Until the reload for this host lands, `flows` may still belong to another screen.
        let flows = model.openHost == host ? model.flows.filter { $0.host == host } : []
        // A selection binding outside Select mode makes iOS 26 push a tapped link twice.
        AppList(plain: true, selection: editMode.isEditing ? $selection : nil) {
            if let error = model.listError {
                Label {
                    Text(error)
                } icon: {
                    Image(symbol: .errorFill).foregroundStyle(.red)
                }
            }
            if !flows.isEmpty { TipView(RequestActionsTip()).tipBackground(Color.card).listRowSeparator(.hidden) }
            if byEndpoint {
                ForEach(EndpointGroup.of(flows)) { group in
                    Section {
                        ForEach(group.flows) { flow in row(flow, path: group.rowPath(flow)) }
                    } header: {
                        HStack {
                            Text(group.key).font(.mono(.footnote)).textCase(nil).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text("\(group.flows.count)").font(.app(.footnote).monospacedDigit())
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(group.key), ^[\(group.flows.count) request](inflect: true)")
                    }
                }
            } else {
                ForEach(flows) { flow in row(flow, path: nil) }
            }
        }
        .listStyle(.plain)
        .overlay {
            if model.loadedHost == host { EmptyListOverlay(empty: flows.isEmpty) } else if flows.isEmpty { ProgressView() }
        }
        .flowSearch(prompt: "Path or URL", regexPrompt: "Regex on URL")
        .navigationTitle(host)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !editMode.isEditing {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    FilterMenu(showFilter: $showFilter, grouping: .domain)
                    moreMenu(canSelect: !flows.isEmpty)
                }
            }
        }
        .navigationBarBackButtonHidden(editMode.isEditing)
        .modifier(FlowSelection(editMode: $editMode, selection: $selection, flows: flows, title: host))
        .sheet(isPresented: $showFilter) { FilterSheet() }
    }

    private func row(_ flow: FlowRecord, path: String?) -> some View {
        RouteLink(.flow(flow)) {
            FlowRow(flow: flow, mark: model.marks[flow.id], showHost: false, path: path)
        }
        .modifier(FlowSwipeActions(flow: flow))
    }

    private func moreMenu(canSelect: Bool) -> some View {
        let favorite = model.domains.first { $0.host == host }?.isFavorite ?? false
        return Menu {
            Section {
                Button("Select") { editMode = .active }
                    .disabled(!canSelect)
            }
            Menu {
                ForEach(ArchiveFormat.allCases) { format in
                    Button(format.rawValue) {
                        Task { await model.share(await model.flowsForExport(host: host), as: format, name: host) }
                    }
                }
            } label: { Text("Export") }
            Section {
                if model.isDecrypting(host) {
                    Button("Don’t Decrypt This Host") { model.stopDecrypting(host) }
                } else {
                    Button("Decrypt This Host") { model.setSSLProxying(host, true) }
                }
                Button { model.toggleFavorite(host) } label: {
                    Text(favorite ? "Remove from Favorites" : "Add to Favorites")
                }
            }
        } label: { Label("More", symbol: .moreHoriz) }
    }
}

/// The requests of one endpoint on the domain screen, newest first.
struct EndpointGroup: Identifiable {
    let key: String
    var flows: [FlowRecord]

    var id: String { key }

    /// Groups flows that are already newest first; groups are ordered by their newest request.
    static func of(_ flows: [FlowRecord]) -> [EndpointGroup] {
        var groups: [EndpointGroup] = []
        var index: [String: Int] = [:]
        for flow in flows {
            let key = flow.endpointKey
            if let i = index[key] { groups[i].flows.append(flow) } else {
                index[key] = groups.count
                groups.append(EndpointGroup(key: key, flows: [flow]))
            }
        }
        return groups
    }

    /// What the row adds to the header: the real path when it was folded, then the query.
    /// Nil keeps the row's usual text, for flows that are not plain HTTP requests.
    func rowPath(_ flow: FlowRecord) -> String? {
        guard flow.hasEndpoint, let url = flow.url, let parts = URLComponents(string: url) else { return nil }
        let path = parts.path.isEmpty ? "/" : parts.path
        // Decoded like `pathText`, so the same query reads the same everywhere.
        let query = parts.query.map { "?" + $0 } ?? ""
        if key.contains(EndpointKey.placeholder) { return path + query }
        return query.isEmpty ? path : query
    }
}

/// Select mode for a flow list, like Photos and Files: a count in the title, then Compare, Export and Highlight at the bottom.
struct FlowSelection: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.inSplitView) private var inSplitView
    @Binding var editMode: EditMode
    @Binding var selection: Set<UUID>
    /// The flows on screen, newest first.
    let flows: [FlowRecord]
    let title: String
    /// Whether this list is the one on screen, so a Select from a context menu lands here.
    var isFrontmost = true

    private var selected: [FlowRecord] { flows.filter { selection.contains($0.id) } }

    /// The `TabItem` tab view of iOS 17 only brings the tab bar back for `.visible`; with the `Tab` tab view of
    /// iOS 18 and later a `.visible` here also beats the `.hidden` of a pushed screen, so its bottom bar ends up under the tab bar.
    private static var tabBarShown: Visibility {
        if #available(iOS 18, *) { .automatic } else { .visible }
    }

    func body(content: Content) -> some View {
        let active = editMode.isEditing
        content
            .environment(\.editMode, $editMode)
            .toolbar(active ? .hidden : Self.tabBarShown, for: .tabBar)
            .toolbar {
                if active {
                    ToolbarItem(placement: .principal) {
                        Text(selection.isEmpty ? "Select Requests" : "\(selection.count) Selected").font(.app(.headline))
                    }
                    ToolbarItem(placement: .confirmationAction) { ConfirmButton(action: end) }
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button("Compare") { compare() }
                            .disabled(selection.count != 2)
                        Spacer()
                        Menu {
                            ForEach(ArchiveFormat.allCases) { format in
                                Button(format.rawValue) {
                                    let chosen = selected
                                    Task { await model.share(chosen, as: format, name: title) }
                                }
                            }
                        } label: { Label("Export", symbol: .iosShare) }
                        .disabled(selection.isEmpty)
                        Spacer()
                        Menu {
                            ForEach(MarkColor.allCases, id: \.self) { color in
                                Button {
                                    for flow in selected { model.setMark(FlowMark(color: color, comment: model.marks[flow.id]?.comment), for: flow.id) }
                                } label: {
                                    Label {
                                        Text(color.title)
                                    } icon: {
                                        // Menus drop SwiftUI tints, so the dot is a pre-colored image.
                                        Image(uiImage: UIImage(symbol: .circleFill)
                                            .withTintColor(UIColor(color.swiftUIColor), renderingMode: .alwaysOriginal))
                                    }
                                }
                            }
                            Button("Remove Highlight") {
                                for flow in selected { model.setMark(FlowMark(color: nil, comment: model.marks[flow.id]?.comment), for: flow.id) }
                            }
                        } label: { Label("Highlight", symbol: .inkHighlighter) }
                        .menuOrder(.fixed)
                        .disabled(selection.isEmpty)
                    }
                }
            }
            .onChange(of: flows.map(\.id)) { _, ids in selection.formIntersection(ids) }
            .onChange(of: model.selectionRequest) {
                guard isFrontmost, let request = model.selectionRequest, flows.contains(where: { $0.id == request.flowID }) else { return }
                model.selectionRequest = nil
                selection = [request.flowID]
                editMode = .active
            }
    }

    /// Compares the two selected flows, the older one as A.
    private func compare() {
        let pair = selected.sorted { $0.startedAt < $1.startedAt }
        guard pair.count == 2 else { return }
        end()
        if inSplitView { model.select(.diff(pair[0], pair[1])) } else { model.path.append(.diff(pair[0], pair[1])) }
    }

    private func end() {
        editMode = .inactive
        selection = []
    }
}

private struct EmptyListOverlay: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSearching) private var isSearching
    let empty: Bool

    var body: some View {
        let searching = !model.search.isEmpty || !model.searchTokens.isEmpty
        if !model.hasLoaded || !model.tunnel.isLoaded {
            ProgressView()
        } else {
            content(searching: searching)
        }
    }

    @ViewBuilder private func content(searching: Bool) -> some View {
        // While the field is focused and empty, search suggestions cover the list.
        if !empty || isSearching && !searching {
            EmptyView()
        } else if searching {
            ContentUnavailableView(searching: model.search)
        } else if model.filter.isDefault {
            if model.tunnel.isRunning {
                ContentUnavailableView("Waiting for Traffic", symbol: .sensors,
                                       description: Text("Open the app you want to inspect."))
            } else {
                ContentUnavailableView {
                    Label(emptyState: "Proxy Off", symbol: .sensorsOff)
                } description: {
                    Text("Turn on the proxy and use any app on this iPhone. Its requests appear here.").font(.app(.body))
                } actions: {
                    Button("Turn On") { Task { await model.toggleTunnel() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.tunnel.isBusy)
                    if model.caTrusted == false && (model.decryptAll || !model.sslProxyingHosts.isEmpty) {
                        Button("Install Certificate…") { model.showCertificateGuide = true }
                    }
                }
            }
        } else {
            ContentUnavailableView {
                Label(emptyState: "No Matching Requests", symbol: .filterList)
            } description: {
                Text("The current filters hide every request.").font(.app(.body))
            } actions: {
                Button("Reset Filters") { model.filter = FlowFilter() }
            }
        }
    }
}

/// Favorite domains in their own section first, then the rest.
private struct DomainRows: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let favorites = model.domains.filter(\.isFavorite)
        if favorites.isEmpty {
            Section { rows(model.domains) }
        } else {
            Section("Favorites") { rows(favorites) }
            Section("Hosts") { rows(model.domains.filter { !$0.isFavorite }) }
        }
    }

    private func rows(_ domains: [DomainSummary]) -> some View {
            ForEach(domains) { domain in
                RouteLink(.domain(domain.host)) { DomainRow(domain: domain) }
                    .swipeActions(edge: .leading) {
                        SwipeAction(domain.isFavorite ? "Unfavorite" : "Favorite", symbol: domain.isFavorite ? .starFill : .star) {
                            model.toggleFavorite(domain.host)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        if model.isDecrypting(domain.host) {
                            SwipeAction("Don’t Decrypt", symbol: .lock) { model.stopDecrypting(domain.host) }
                        } else {
                            SwipeAction("Decrypt", symbol: .lockOpen) { model.setSSLProxying(domain.host, true) }
                        }
                    }
                    .contextMenu {
                        Button { model.toggleFavorite(domain.host) } label: {
                            Text(domain.isFavorite ? "Remove from Favorites" : "Add to Favorites")
                        }
                        Button("Search This Host") { model.search = domain.host }
                        if model.isDecrypting(domain.host) {
                            Button("Don’t Decrypt This Host") { model.stopDecrypting(domain.host) }
                        } else {
                            Button("Decrypt This Host") { model.setSSLProxying(domain.host, true) }
                        }
                    }
            }
    }
}

/// Swipe right to repeat a request, left to toggle its highlight in the last color used.
struct FlowSwipeActions: ViewModifier {
    @Environment(AppModel.self) private var model
    @AppStorage("lastMarkColor") private var lastColor = MarkColor.yellow
    let flow: FlowRecord

    func body(content: Content) -> some View {
        let mark = model.marks[flow.id]
        content
            .swipeActions(edge: .leading) {
                if model.canResend(flow) && model.tunnel.isRunning {
                    SwipeAction("Repeat", symbol: .refresh) {
                        Task {
                            if let error = await model.repeatFlow(flow) {
                                model.alert = AppAlert(title: "Couldn’t Repeat Request", message: error)
                            }
                        }
                    }
                }
            }
            .swipeActions(edge: .trailing) {
                SwipeAction(mark?.color == nil ? "Highlight" : "Remove Highlight", symbol: .inkHighlighter,
                            color: mark?.color == nil ? lastColor.swiftUIColor : .secondary) {
                    let color: MarkColor? = mark?.color == nil ? lastColor : nil
                    model.setMark(FlowMark(color: color, comment: mark?.comment), for: flow.id)
                }
            }
    }
}

private struct DomainRow: View {
    @Environment(AppModel.self) private var model
    let domain: DomainSummary

    var body: some View {
        let sslListed = model.isDecrypting(domain.host) && !model.decryptAll
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(domain.host).font(.app(.subheadline, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text("\(domain.count)").font(.app(.caption).monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    subtitle.font(.app(.caption)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    if sslListed { Image(symbol: .lockOpen).font(.app(.caption)).foregroundStyle(.secondary) }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([
            domain.host,
            domain.isFavorite ? "favorite" : nil,
            domain.count == 1 ? "1 request" : "\(domain.count) requests",
            domain.errorCount > 0 ? (domain.errorCount == 1 ? "1 error" : "\(domain.errorCount) errors") : nil,
            domain.tlsFailureCount > 0 ? (domain.tlsFailureCount == 1 ? "1 failed TLS handshake" : "\(domain.tlsFailureCount) failed TLS handshakes") : nil,
            sslListed ? "decrypting HTTPS" : nil,
        ].compactMap { $0 }.joined(separator: ", "))
    }

    private var subtitle: Text {
        var parts: [Text] = []
        if domain.errorCount > 0 {
            parts.append(Text(domain.errorCount == 1 ? "1 error" : "\(domain.errorCount) errors").foregroundColor(.red))
        }
        if domain.tlsFailureCount > 0 { parts.append(Text("TLS failed ×\(domain.tlsFailureCount)")) }
        parts.append(Text(domain.lastAt, format: .dateTime.hour().minute().second()))
        return parts.dropFirst().reduce(parts[0]) { $0 + Text(" · ") + $1 }
    }
}

/// The single most important warning above the list, with a count of the others.
private struct StatusBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorSchemeContrast) private var contrast

    private struct Banner {
        let text: String
        let symbol: AppSymbol
        let color: Color
        var dismiss: (() -> Void)? = nil
        var action: (() -> Void)? = nil
    }

    var body: some View {
        let all = banners
        if let first = all.first {
            HStack(alignment: .top, spacing: 8) {
                Button { first.action?() } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Label {
                            Text(first.text).foregroundStyle(.primary)
                        } icon: {
                            Image(symbol: first.symbol).foregroundStyle(first.color)
                        }
                        .font(.app(.subheadline))
                        Spacer(minLength: 4)
                        if all.count > 1 {
                            Text("+\(all.count - 1)").font(.app(.caption, weight: .bold)).foregroundStyle(.secondary)
                                .accessibilityLabel("^[\(all.count - 1) more warning](inflect: true)")
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .allowsHitTesting(first.action != nil)
                .accessibilityHint(first.action == nil ? "" : "Opens the fix for this warning.")
                if let dismiss = first.dismiss {
                    Button(action: dismiss) {
                        Image(symbol: .cancelFill).symbolRenderingMode(.hierarchical).foregroundStyle(.secondary)
                            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .padding(.vertical, -12)
                    .accessibilityLabel("Dismiss")
                }
            }
            .listRowBackground(first.color.opacity(contrast == .increased ? 0.24 : 0.12))
            .listRowSeparator(.hidden)
        }
    }

    private var banners: [Banner] {
        var out: [Banner] = []
        let decrypting = model.decryptAll || !model.sslProxyingHosts.isEmpty
        if let error = model.storeError { out.append(Banner(text: error, symbol: .errorFill, color: .red)) }
        if let error = model.tunnel.lastError {
            out.append(Banner(text: error, symbol: .errorFill, color: .red, dismiss: model.tunnel.clearError))
        }
        if decrypting, model.caExpiry == .expired, let warning = model.caExpiryWarning {
            out.append(Banner(text: warning, symbol: .eventBusy, color: .red) { model.showHTTPSSettings = true })
        }
        if model.tunnel.isRunning && model.caTrusted == false && decrypting {
            out.append(Banner(text: "To decrypt HTTPS, install and trust the Passage certificate.",
                              symbol: .gppBadFill, color: .orange) { model.showCertificateGuide = true })
        }
        if decrypting, case .expiresSoon? = model.caExpiry, let warning = model.caExpiryWarning {
            out.append(Banner(text: warning, symbol: .eventBusy, color: .orange) { model.showHTTPSSettings = true })
        }
        if model.lowMemory {
            out.append(Banner(text: "Memory is low. New HTTPS connections pass through without decryption, and bodies aren’t saved.",
                              symbol: .memory, color: .orange))
        }
        if let message = model.lastStopMessage {
            out.append(Banner(text: message, symbol: .warningFill, color: .orange, dismiss: model.dismissStopMessage))
        }
        if let error = model.listError { out.append(Banner(text: error, symbol: .errorFill, color: .red)) }
        return out
    }
}

struct FlowRow: View {
    @Environment(AppModel.self) private var model
    let flow: FlowRecord
    let mark: FlowMark?
    var showHost = true
    /// Replaces the path on line one, for rows under an endpoint header.
    var path: String? = nil
    /// Off in sheets, where the actions' own sheets and navigation cannot open.
    var actions = true
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let large = typeSize.isAccessibilitySize
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(mark?.color?.swiftUIColor ?? .clear)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(flow.methodText)
                        .font(.mono(.caption).bold())
                        .frame(minWidth: 44, alignment: .leading)
                    Text(flow.graphQL ?? path ?? flow.rowPath)
                        .font(.mono(.subheadline))
                        .lineLimit(large ? 2 : 1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    ForEach(RuleBadge.badges(for: flow), id: \.symbol) { badge in
                        Image(symbol: badge.symbol).font(.app(.caption)).foregroundStyle(badge.color)
                    }
                    if mark?.comment?.isEmpty == false {
                        Image(symbol: .chat).font(.app(.caption)).foregroundStyle(.secondary)
                    }
                }
                if large {
                    // At accessibility sizes the details get their own lines instead of being cut off.
                    HStack(spacing: 6) {
                        StatusText(flow: flow)
                        time
                    }
                    details.font(.app(.caption)).foregroundStyle(.secondary).lineLimit(3)
                } else {
                    HStack(spacing: 6) {
                        StatusText(flow: flow)
                            .frame(minWidth: 44, alignment: .leading)
                        details
                            .font(.app(.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        time
                    }
                }
            }
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .contextMenu {
            if actions { FlowActions(flow: flow) }
        } preview: {
            FlowRow(flow: flow, mark: mark, showHost: true, actions: false)
                .padding()
                .frame(width: 340)
                .environment(model)
        }
    }

    private var time: some View {
        Text(flow.startedAt, format: .dateTime.hour().minute().second())
            .font(.app(.caption2).monospacedDigit())
            .foregroundStyle(.secondary)
    }

    /// Host, protocol, duration and a large response size, joined by middle dots.
    private var details: Text {
        var parts: [Text] = []
        if showHost { parts.append(Text(flow.host)) }
        if flow.graphQL != nil { parts.append(Text("GQL").foregroundColor(.purple)) }
        else if flow.httpVersion == "HTTP/2" { parts.append(Text("H2")) }
        if flow.note?.hasPrefix("Pinned") == true { parts.append(Text("Pinned")) }
        if let ms = flow.durationMs { parts.append(Text(Self.duration(ms))) }
        if flow.responseBytes > 100_000 {
            parts.append(Text(Int64(flow.responseBytes), format: .byteCount(style: .file)))
        }
        guard var out = parts.first else { return Text("") }
        for part in parts.dropFirst() { out = out + Text(" · ") + part }
        return out
    }

    static func duration(_ ms: Double) -> String { ms < 1000 ? "\(Int(ms)) ms" : String(format: "%.2f s", ms / 1000) }

    private var accessibilityText: String {
        [
            flow.methodText,
            StatusBadge.text(flow),
            flow.graphQL,
            flow.rowPath,
            showHost ? flow.host : nil,
            flow.durationMs.map(Self.duration),
            RuleBadge.toolTitles(for: flow),
            mark?.color.map { "highlighted \($0.title.lowercased())" },
            mark?.comment?.isEmpty == false ? "has comment" : nil,
            flow.note?.hasPrefix("Pinned") == true ? "pinned, not decrypted" : nil,
        ].compactMap { $0 }.joined(separator: ", ")
    }
}

/// The status column of a flow row: the code in its status color, or a symbol for states without one.
struct StatusText: View {
    let flow: FlowRecord

    var body: some View {
        switch flow.state {
        case .active:
            ProgressView().controlSize(.mini).accessibilityLabel("In progress")
        case .paused:
            Label("Paused", symbol: .pauseCircleFill).labelStyle(.iconOnly).foregroundStyle(.statusWarning).font(.app(.caption))
        case .failed:
            if flow.isUndecrypted {
                Image(symbol: .noEncryption).font(.app(.caption)).foregroundStyle(.secondary)
            } else {
                Label("Failed", symbol: .dangerousFill).font(.app(.caption, weight: .bold)).foregroundStyle(.statusError)
            }
        case .completed:
            if let code = flow.statusCode, flow.kind == .http || flow.kind == .https {
                Text(String(code)).font(.app(.caption).monospacedDigit().bold()).foregroundStyle(StatusBadge.color(flow))
            } else if flow.isUndecrypted {
                Image(symbol: .lockFill).font(.app(.caption)).foregroundStyle(.secondary)
            } else {
                Text("—").font(.app(.caption)).foregroundStyle(.secondary)
            }
        }
    }
}
