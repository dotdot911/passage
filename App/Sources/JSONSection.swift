import SwiftUI
import Viewing

/// A collapsible JSON tree with a JSONPath query field, as List sections.
/// The tree inline in a tab; search and JSONPath live in `BodyViewer`.
struct JSONSection: View {
    let root: JSONNode
    var queryable = false
    @State private var query = ""
    @State private var result: Result<[JSONPath.Match], JSONPath.SyntaxError>?

    var body: some View {
        if queryable { querySection }
        Section {
            if case .success(let matches) = result {
                ForEach(Array(matches.prefix(JSONNodeRow.maxChildren).enumerated()), id: \.offset) { _, match in
                    JSONNodeRow(label: match.path, path: match.path, node: match.node, depth: 2)
                }
            } else {
                JSONRootRows(root: root)
            }
        }
    }

    private var querySection: some View {
        Section {
            TextField("JSONPath", text: $query, prompt: Text(verbatim: "$.items[*].id")).submitLabel(.search)
                .font(.mono(.caption))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(run)
                .onChange(of: query) { if query.isEmpty { result = nil } }
            switch result {
            case .failure(let error):
                Text(error.description).font(.app(.caption)).foregroundStyle(.statusError)
            case .success(let matches):
                Text(matches.count == 1 ? "1 match" : "\(matches.count) matches").font(.app(.caption)).foregroundStyle(.secondary)
            case nil:
                EmptyView()
            }
        }
    }

    private func run() {
        guard !query.isEmpty else { result = nil; return }
        do { result = .success(try JSONPath(query).evaluate(root)) } catch { result = .failure(error) }
    }
}

/// One JSON value; containers expand into their children. The first two levels start open.
struct JSONNodeRow: View {
    static let maxChildren = 500

    let label: String?
    let path: String
    let node: JSONNode
    let depth: Int
    /// Puts the label above the value, for long labels such as search result paths.
    var stacked = false
    @State private var expanded: Bool

    init(label: String?, path: String, node: JSONNode, depth: Int, stacked: Bool = false) {
        self.label = label
        self.path = path
        self.node = node
        self.depth = depth
        self.stacked = stacked
        _expanded = State(initialValue: depth < 2)
    }

    var body: some View {
        switch node {
        case .object(let members):
            DisclosureGroup(isExpanded: $expanded) {
                if expanded {
                    ForEach(Array(members.prefix(Self.maxChildren).enumerated()), id: \.offset) { _, m in
                        JSONNodeRow(label: m.key, path: path + JSONPath.key(m.key), node: m.value, depth: depth + 1)
                    }
                    more(members.count)
                }
            } label: { header("{ \(members.count) }") }
        case .array(let items):
            DisclosureGroup(isExpanded: $expanded) {
                if expanded {
                    ForEach(Array(items.prefix(Self.maxChildren).enumerated()), id: \.offset) { i, item in
                        JSONNodeRow(label: "[\(i)]", path: path + "[\(i)]", node: item, depth: depth + 1)
                    }
                    more(items.count)
                }
            } label: { header("[ \(items.count) ]") }
        default:
            let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                                 : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
            layout {
                if let label {
                    Text(label).font(.mono(.caption).bold()).foregroundStyle(stacked ? .secondary : .primary)
                }
                Text(scalarText).font(.mono(.caption)).foregroundStyle(scalarColor)
            }
            .contextMenu { copyMenu }
        }
    }

    private func header(_ summary: String) -> some View {
        HStack {
            if let label { Text(label).font(.mono(.caption).bold()) }
            Text(summary).font(.mono(.caption)).foregroundStyle(.secondary)
        }
        .contextMenu { copyMenu }
    }

    @ViewBuilder
    private func more(_ count: Int) -> some View {
        if count > Self.maxChildren {
            Text("… \(count - Self.maxChildren) more").font(.app(.caption)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var copyMenu: some View {
        Button("Copy Value") { UIPasteboard.general.string = copyValue }
        Button("Copy Path") { UIPasteboard.general.string = path }
    }

    private var copyValue: String {
        if case .string(let s) = node { return s }
        return node.serialized(pretty: true)
    }

    private var scalarText: String { node.serialized() }

    private var scalarColor: Color {
        switch node {
        case .string: .statusSuccess
        case .number: .blue
        case .bool: .statusWarning
        default: .secondary
        }
    }
}

/// The top level of a JSON document as rows, without an unlabeled "{ N }" row to open first.
struct JSONRootRows: View {
    let root: JSONNode

    var body: some View {
        switch root {
        case .object(let members):
            ForEach(Array(members.prefix(JSONNodeRow.maxChildren).enumerated()), id: \.offset) { _, m in
                JSONNodeRow(label: m.key, path: "$" + JSONPath.key(m.key), node: m.value, depth: 1)
            }
            if members.count > JSONNodeRow.maxChildren { overflow(members.count) }
        case .array(let items):
            ForEach(Array(items.prefix(JSONNodeRow.maxChildren).enumerated()), id: \.offset) { i, item in
                JSONNodeRow(label: "[\(i)]", path: "$[\(i)]", node: item, depth: 1)
            }
            if items.count > JSONNodeRow.maxChildren { overflow(items.count) }
        default:
            JSONNodeRow(label: nil, path: "$", node: root, depth: 0)
        }
    }

    private func overflow(_ total: Int) -> some View {
        Text("… \(total - JSONNodeRow.maxChildren) more").font(.app(.caption)).foregroundStyle(.secondary)
    }
}
