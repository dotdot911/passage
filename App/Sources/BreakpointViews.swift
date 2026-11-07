import ProxyModel
import SwiftUI
import Viewing

/// A bar above the tab bar on every tab while something waits at a breakpoint, like the mini player in Music.
struct BreakpointBanner: View {
    @Environment(AppModel.self) private var model
    /// Drawn by a screen's own bottom bar; the tab-wide banner stands aside while such a screen is showing.
    var inBottomBar = false

    var body: some View {
        if let first = model.pausedBreakpoints.first, inBottomBar || model.bottomBarScreens == 0 {
            let count = model.pausedBreakpoints.count
            HStack(spacing: 12) {
                Button { model.presentBreakpoint(first) } label: {
                    HStack(spacing: 12) {
                        Image(symbol: .pauseCircleFill).font(.app(.title2)).foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(count == 1 ? first.title : "\(first.title) · 1 of \(count)").font(.app(.subheadline, weight: .semibold))
                                Text(timerInterval: Date()...max(Date(), first.deadline), countsDown: true)
                                    .font(.app(.caption).monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Text("\(first.method) \(first.url)")
                                .font(.mono(.caption)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button { Task { await model.resolve(first, decision: .execute(first.unchangedEdit), body: nil) } } label: {
                    Image(symbol: .playArrowFill).font(.app(.title3))
                        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Execute Unchanged")
            }
            .padding(.horizontal).padding(.vertical, 10)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityLabel("\(first.title) by rule \(first.ruleName)")
        }
    }
}

extension BreakpointItem {
    /// Lets the message continue exactly as it was paused.
    var unchangedEdit: BreakpointEdit {
        BreakpointEdit(method: method, url: url, status: status, headers: headers)
    }
}

/// Edits a paused request or response, then lets it continue or aborts it. Swiping it down keeps the message paused.
struct BreakpointEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: BreakpointItem
    /// Shows another paused message in the same sheet.
    var step: (BreakpointItem) -> Void = { _ in }
    @State private var method = ""
    @State private var url = ""
    @State private var status = 200
    @State private var headers: [EditableHeader] = []
    @State private var bodyText = ""
    @State private var binaryBody: Data?
    @State private var loaded = false
    /// Past the deadline the tunnel has already let the message continue.
    @State private var expired = false
    /// The client disconnected while the message waited, so nothing can be sent on its behalf.
    private var dropped: Bool { model.droppedBreakpoints.contains(item.id) }
    private var ended: Bool { expired || dropped }
    @State private var notJSON = false

    var body: some View {
        NavigationStack {
            AppForm {
                Section {
                    if item.phase == .request {
                        Picker("Method", selection: $method) {
                            ForEach(Array(Set(ComposeDraft.methods + [method])).sorted(), id: \.self) { Text($0) }
                        }
                        TextField("URL", text: $url, axis: .vertical).font(.mono(.body)).keyboardType(.URL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    } else {
                        LabeledContent("Status") {
                            IntField("200", value: $status)
                        }
                        Text(item.url).font(.mono(.caption)).foregroundStyle(.secondary)
                    }
                } header: { Text(item.phase == .request ? "Request" : "Response") } footer: {
                    SectionFooter {
                        if dropped {
                            Text("Paused by “\(item.ruleName)”. The app closed the connection, so this message can’t continue.")
                        } else if expired {
                            Text("Paused by “\(item.ruleName)”. Time ran out, so it continued unchanged.")
                        } else {
                            Text("Paused by “\(item.ruleName)”. Continues unchanged in \(Text(timerInterval: Date()...max(Date(), item.deadline), countsDown: true)).")
                        }
                    }
                }
                Section("Headers") {
                    ForEach($headers) { $h in
                        HStack(alignment: .top, spacing: 2) {
                            Button { h.enabled.toggle() } label: {
                                Image(symbol: h.enabled ? .checkCircleFill : .circle)
                                    .foregroundStyle(h.enabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(h.name.isEmpty ? "Header" : h.name)
                            .accessibilityValue(h.enabled ? "On" : "Off")
                            .accessibilityAddTraits(.isToggle)
                            VStack(spacing: 4) {
                                TextField("Name", text: $h.name).font(.app(.caption, weight: .bold))
                                TextField("Value", text: $h.value, axis: .vertical).font(.mono(.caption))
                            }
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .opacity(h.enabled ? 1 : 0.4)
                        }
                        .deleteSwipe { headers.removeAll { $0.id == h.id } }
                    }
                    .onDelete { headers.remove(atOffsets: $0) }
                    Button("Add Header") { headers.append(EditableHeader(name: "", value: "")) }
                }
                Section {
                    if let binaryBody {
                        LabeledContent("Binary Body", value: ByteCountFormatter.string(fromByteCount: Int64(binaryBody.count), countStyle: .file))
                    } else {
                        TextEditor(text: $bodyText).font(.mono(.caption)).frame(minHeight: 160)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                } header: {
                    HStack {
                        Text("Body")
                        Spacer()
                        if binaryBody == nil {
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
            }
            .scrollDismissesKeyboard(.interactively)
            .keyboardDoneButton()
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let index = model.pausedBreakpoints.firstIndex(where: { $0.id == item.id }), model.pausedBreakpoints.count > 1 {
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 0) {
                            Text(item.title).font(.app(.headline))
                            Text("\(index + 1) of \(model.pausedBreakpoints.count)").font(.app(.caption2)).foregroundStyle(.secondary)
                        }
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { step(model.pausedBreakpoints[index - 1]) } label: { Label("Previous Paused Message", symbol: .keyboardArrowUp) }
                            .disabled(index == 0)
                        Button { step(model.pausedBreakpoints[index + 1]) } label: { Label("Next Paused Message", symbol: .keyboardArrowDown) }
                            .disabled(index + 1 >= model.pausedBreakpoints.count)
                    }
                }
                if ended {
                    ToolbarItem(placement: .cancellationAction) { CloseButton { dismiss() } }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Abort", role: .destructive) { finish(.abort) }
                        .disabled(ended)
                    Spacer()
                    Menu {
                        Button("Execute Unchanged") { finish(.execute(item.unchangedEdit), body: nil) }
                    } label: { Label("More", symbol: .moreHoriz) }
                    .disabled(ended)
                    Spacer()
                    Button("Execute") { finish(.execute(edit)) }
                        .buttonStyle(.borderedProminent)
                        .disabled(ended)
                }
            }
            .presentationDragIndicator(.visible)
            .task { load() }
            .task(id: item.id) {
                let wait = item.deadline.timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                if !Task.isCancelled { expired = true }
            }
            .onDisappear(perform: keepDraft)
        }
    }

    private func reformat(pretty: Bool) {
        if let text = JSONFormatter.format(bodyText, pretty: pretty) { bodyText = text; notJSON = false } else { notJSON = true }
    }

    private var edit: BreakpointEdit {
        BreakpointEdit(method: method, url: url, status: item.phase == .response ? status : nil,
                       headers: headers.filter { $0.enabled && !$0.name.isEmpty }.map { HeaderField(name: $0.name, value: $0.value) })
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let draft = model.breakpointDrafts[item.id] {
            (method, url, status, headers, bodyText, binaryBody) =
                (draft.method, draft.url, draft.status, draft.headers, draft.bodyText, draft.binaryBody)
            return
        }
        method = item.method
        url = item.url
        status = item.status ?? 200
        headers = item.headers.map { EditableHeader(name: $0.name, value: $0.value) }
        let data = model.breakpointBodyURL(item).flatMap { try? Data(contentsOf: $0) } ?? Data()
        if let text = String(data: data, encoding: .utf8) {
            bodyText = text
            return
        }
        // Most APIs compress responses. Decoded text is editable; it is sent uncompressed, so Content-Encoding goes.
        let encoding = item.headers.first { $0.name.lowercased() == "content-encoding" }?.value
        let decoded = BodyDecoder.decode(data, contentEncoding: encoding)
        if encoding != nil, decoded.error == nil, let text = String(data: decoded.data, encoding: .utf8) {
            bodyText = text
            headers.removeAll { $0.name.lowercased() == "content-encoding" }
        } else {
            binaryBody = data
        }
    }

    /// Keeps the edits while the message is still paused, so swiping the editor away loses nothing.
    private func keepDraft() {
        guard loaded, model.pausedBreakpoints.contains(where: { $0.id == item.id }) else { return }
        model.breakpointDrafts[item.id] = BreakpointDraft(method: method, url: url, status: status, headers: headers,
                                                          bodyText: bodyText, binaryBody: binaryBody)
    }

    private func finish(_ decision: BreakpointDecision) {
        finish(decision, body: binaryBody == nil ? Data(bodyText.utf8) : nil)
    }

    private func finish(_ decision: BreakpointDecision, body: Data?) {
        Task { await model.resolve(item, decision: decision, body: body) }
        dismiss()
    }
}

/// The breakpoint editor with its own current message, so stepping between paused messages swaps the content in place.
struct BreakpointSheet: View {
    @State var item: BreakpointItem

    var body: some View {
        BreakpointEditor(item: item, step: { item = $0 }).id(item.id)
            .editorSheetSizing()
    }
}

extension AppModel {
    /// Opens the editor for a paused message. When another sheet is already up, SwiftUI cannot present a second one
    /// from the root, so the editor goes on top of whatever is showing.
    func presentBreakpoint(_ item: BreakpointItem) {
        guard let root = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first?.rootViewController,
              var top = root.presentedViewController else {
            editingBreakpoint = item
            return
        }
        while let next = top.presentedViewController { top = next }
        if top is UIHostingController<AnyView> { return }
        top.present(UIHostingController(rootView: AnyView(BreakpointSheet(item: item).themedContent().environment(self))), animated: true)
    }
}

/// A whole-number field that updates its value on every keystroke, so a toolbar button tapped before the keyboard
/// closes still sees what was typed (`TextField(value:format:)` only commits on Return or losing focus).
struct IntField: View {
    let placeholder: String
    @Binding var value: Int?
    @State private var text: String

    init(_ placeholder: String, value: Binding<Int?>) {
        self.placeholder = placeholder
        _value = value
        _text = State(initialValue: value.wrappedValue.map(String.init) ?? "")
    }

    init(_ placeholder: String, value: Binding<Int>) {
        self.init(placeholder, value: Binding<Int?>(get: { value.wrappedValue }, set: { if let v = $0 { value.wrappedValue = v } }))
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
            .onChange(of: text) {
                let digits = text.filter(\.isNumber)
                if digits != text { text = digits }
                value = Int(digits)
            }
    }
}
