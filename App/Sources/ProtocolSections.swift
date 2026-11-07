import ProxyModel
import SwiftUI
import Viewing

/// Schema-less protobuf messages (one per gRPC frame) as collapsible field trees.
struct ProtobufSection: View {
    let messages: [ProtobufMessage]

    var body: some View {
        ForEach(Array(messages.enumerated()), id: \.offset) { i, message in
            Section {
                if let error = message.error {
                    Text("Not valid Protobuf: \(error)").font(.app(.caption)).foregroundStyle(.statusError)
                }
                if let fields = message.fields {
                    ForEach(Array(fields.enumerated()), id: \.offset) { _, field in ProtobufFieldRow(field: field, depth: 0) }
                }
                if let trailers = message.trailers {
                    Text(trailers).font(.mono(.caption)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } header: {
                HStack {
                    Text(messages.count > 1 ? "Message \(i + 1)" : "Protobuf")
                    Spacer()
                    if i == 0 { Button("Copy") { UIPasteboard.general.string = BodyPreview.protobufText(messages) }.headerControl() }
                }
                .textCase(nil)
            }
        }
    }
}

/// One field; nested messages expand. The first two levels start open.
private struct ProtobufFieldRow: View {
    let field: ProtobufField
    let depth: Int
    @State private var expanded: Bool

    init(field: ProtobufField, depth: Int) {
        self.field = field
        self.depth = depth
        _expanded = State(initialValue: depth < 2)
    }

    var body: some View {
        if case .message(let children) = field.value {
            DisclosureGroup(isExpanded: $expanded) {
                if expanded {
                    ForEach(Array(children.enumerated()), id: \.offset) { _, child in ProtobufFieldRow(field: child, depth: depth + 1) }
                }
            } label: {
                HStack {
                    Text("#\(field.number)").font(.mono(.caption).bold())
                    Text("message { \(children.count) }").font(.mono(.caption)).foregroundStyle(.secondary)
                }
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text("#\(field.number)").font(.mono(.caption).bold())
                Text(kind).font(.mono(.caption2)).foregroundStyle(.secondary)
                Text(ProtobufDecoder.display(field.value)).font(.mono(.caption)).foregroundStyle(color)
            }
            .contextMenu {
                Button("Copy Value") { UIPasteboard.general.string = ProtobufDecoder.display(field.value) }
            }
        }
    }

    private var kind: String {
        switch field.value {
        case .varint: "varint"
        case .fixed64: "fixed64"
        case .fixed32: "fixed32"
        case .bytes: "bytes"
        case .string: "string"
        case .message: "message"
        }
    }

    private var color: Color {
        switch field.value {
        case .string: .statusSuccess
        case .varint, .fixed32, .fixed64: .blue
        default: .secondary
        }
    }
}

/// A binary body that may still be protobuf without saying so: hex, plus a button to try.
struct BinaryWithProtobufSection<Hex: View>: View {
    let data: Data
    @ViewBuilder let hex: () -> Hex
    @State private var decoded: [ProtobufMessage]?

    var body: some View {
        if let decoded {
            ProtobufSection(messages: decoded)
        } else {
            Section {
                Button("Decode as Protobuf") {
                    let data = data
                    Task { decoded = await Task.detached { BodyPreview.decodeProtobuf(data) }.value }
                }
            }
        }
        Section { hex() }
    }
}

/// Operation, formatted query and variables of each GraphQL request in a body (several for a batch).
struct GraphQLSections: View {
    let requests: [(request: GraphQLRequest, formatted: String)]

    /// Parsed and formatted once per flow: request bodies do not change after they are recorded.
    @MainActor private static var cache: [UUID: [(request: GraphQLRequest, formatted: String)]] = [:]

    init(flow: FlowRecord, body: Data) {
        if let cached = Self.cache[flow.id] {
            requests = cached
        } else {
            requests = GraphQLRequest.parse(method: flow.method ?? "", url: flow.url ?? "", body: body)
                .map { ($0, GraphQLFormatter.format($0.query)) }
            if Self.cache.count > 200 { Self.cache.removeAll() }
            Self.cache[flow.id] = requests
        }
    }

    var body: some View {
        ForEach(Array(requests.enumerated()), id: \.offset) { i, item in
            let request = item.request
            Section {
                if let name = request.operationName { LabeledContent("Operation", value: name).font(.app(.subheadline)) }
                Text(item.formatted).font(.mono(.caption)).textSelection(.enabled)
            } header: {
                HStack {
                    Text(requests.count > 1 ? "GraphQL \(i + 1)" : "GraphQL")
                    Spacer()
                    Button("Copy") { UIPasteboard.general.string = item.formatted }.headerControl()
                }
                .textCase(nil)
            }
            if let variables = request.variables {
                Section("Variables") { JSONRootRows(root: variables) }
            }
        }
    }
}
