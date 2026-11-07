import ProxyModel
import Storage
import SwiftUI
import Viewing

/// The Messages tab of a WebSocket flow: every message in order, newest at the bottom, updated live.
struct WebSocketMessagesView: View {
    @Environment(AppModel.self) private var model
    let flow: FlowRecord
    @State private var messages: [WebSocketMessage] = []
    @State private var direction: DirectionFilter = .all
    @State private var search = ""

    enum DirectionFilter: String, CaseIterable { case all = "All", sent = "Sent", received = "Received" }

    var body: some View {
        let shown = filtered
        ScrollViewReader { proxy in
            AppList {
                ForEach(shown, id: \.seq) { m in
                    NavigationLink { WebSocketMessageDetail(message: m) } label: { WebSocketMessageRow(message: m) }
                        .id(m.seq)
                }
            }
            .overlay {
                if messages.isEmpty {
                    ContentUnavailableView("No Messages", symbol: .forum,
                                           description: Text("Messages appear here as they are sent and received."))
                } else if shown.isEmpty {
                    ContentUnavailableView(searching: search)
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search messages")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .searchScopes($direction) {
                ForEach(DirectionFilter.allCases, id: \.self) { Text($0.rawValue) }
            }
            .onChange(of: messages.count) { _, _ in
                if let last = filtered.last { proxy.scrollTo(last.seq, anchor: .bottom) }
            }
        }
        .task(id: "\(flow.id)-\(model.dbChanges)") { await load() }
    }

    private var filtered: [WebSocketMessage] {
        messages.filter { m in
            switch direction {
            case .all: break
            case .sent: if m.direction != .sent { return false }
            case .received: if m.direction != .received { return false }
            }
            return search.isEmpty || String(decoding: m.payload, as: UTF8.self).localizedCaseInsensitiveContains(search)
        }
    }

    private func load() async {
        guard let store = model.store else { return }
        let id = flow.id
        let loaded = await Task.detached(priority: .userInitiated) { (try? store.webSocketMessages(flowID: id)) ?? [] }.value
        if loaded.count != messages.count { messages = loaded }
    }
}

private struct WebSocketMessageRow: View {
    let message: WebSocketMessage

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(symbol: message.direction == .sent ? .arrowUpward : .arrowDownward)
                .font(.app(.caption, weight: .bold))
                .foregroundStyle(.secondary)
                .accessibilityLabel(message.direction == .sent ? "Sent" : "Received")
            VStack(alignment: .leading, spacing: 2) {
                Text(preview).font(.mono(.caption)).lineLimit(2)
                HStack(spacing: 6) {
                    Text(message.opcode.rawValue.uppercased())
                    Text(ByteCountFormatter.string(fromByteCount: Int64(message.length), countStyle: .file))
                    Text(message.at, format: .dateTime.hour().minute().second())
                }
                .font(.app(.caption2).monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var preview: String {
        switch message.opcode {
        case .text: String(decoding: message.payload.prefix(200), as: UTF8.self)
        case .binary: message.payload.prefix(24).map { String(format: "%02x", $0) }.joined(separator: " ")
        case .close: message.payload.count >= 2 ? "Close \(Int(message.payload[0]) << 8 | Int(message.payload[1]))" : "Close"
        case .ping: "Ping"
        case .pong: "Pong"
        }
    }
}

/// One message's payload, shown with the same previewers as a body (JSON tree, text, hex).
private struct WebSocketMessageDetail: View {
    let message: WebSocketMessage
    @State private var load = BodyLoad.loading

    var body: some View {
        AppList {
            Section("General") {
                LabeledContent("Direction", value: message.direction == .sent ? "Sent" : "Received")
                LabeledContent("Type", value: message.opcode.rawValue.capitalized)
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(message.length), countStyle: .file))
                LabeledContent("Time", value: message.at.formatted(date: .omitted, time: .standard))
                if message.truncated { Text("Only the first 256 KB were kept.").foregroundStyle(.secondary) }
            }
            BodySection(load: load)
        }
        .navigationTitle(message.direction == .sent ? "Sent" : "Received")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let payload = message.payload
            load = await Task.detached(priority: .userInitiated) { () -> BodyLoad in
                payload.isEmpty ? .empty : .loaded(LoadedBody(BodyPreview(raw: payload, storedSize: payload.count, headers: [])))
            }.value
        }
    }
}
