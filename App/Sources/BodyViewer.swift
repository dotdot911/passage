import SwiftUI
import Viewing

/// A whole body on its own screen: Tree, Text or Hex, with search (JSONPath when it starts with `$`).
struct BodyViewer: View {
    @Environment(AppModel.self) private var model
    let loaded: LoadedBody
    let title: String
    @State private var mode: Mode
    @State private var query = ""
    @State private var text: String?
    @State private var hex: String?
    @State private var findRequest = 0

    enum Mode: String { case tree = "Tree", preview = "Preview", text = "Text", hex = "Hex" }

    init(loaded: LoadedBody, title: String, textMode: Bool = false) {
        self.loaded = loaded
        self.title = title
        _mode = State(initialValue: textMode ? .text : loaded.preview.json != nil ? .tree : .preview)
    }

    private var preview: BodyPreview { loaded.preview }
    private var modes: [Mode] { [preview.json != nil ? .tree : .preview, .text, .hex] }

    var body: some View {
        Group {
            switch mode {
            case .tree:
                if let root = preview.json {
                    AppList { JSONSearchResults(root: root, query: query) }
                }
            case .preview:
                if case .html = preview.kind {
                    OfflineWebView(html: String(decoding: preview.decoded.data, as: UTF8.self))
                } else {
                    AppList { BodyAutoPreview(loaded: loaded) }
                }
            case .text:
                if let text { ReadOnlyTextView(text: text, findRequest: findRequest, findQuery: query).ignoresSafeArea(.container, edges: .bottom) } else { ProgressView() }
            case .hex:
                if let hex { ReadOnlyTextView(text: hex, findRequest: findRequest, findQuery: query).ignoresSafeArea(.container, edges: .bottom) } else { ProgressView() }
            }
        }
        // One search field for every mode, so switching modes does not move the content.
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: mode == .tree ? "Search, or $.path for JSONPath" : "Find in Body")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .onSubmit(of: .search) {
            guard mode != .tree, !query.isEmpty else { return }
            if mode == .preview { mode = .text }
            findRequest += 1
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $mode) {
                    ForEach(modes, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Copy Body") { UIPasteboard.general.string = preview.fullText() }
                    Button("Share Body…") { model.shareText(preview.fullText()) }
                } label: { Label("More", symbol: .moreHoriz) }
            }
        }
        .task(id: mode) {
            let preview = preview
            switch mode {
            case .text where text == nil:
                text = await Task.detached { preview.fullText() }.value
            case .hex where hex == nil:
                let data = preview.decoded.data
                hex = await Task.detached { HexDump.text(data.prefix(HexDump.maxViewerBytes)) }.value
            default:
                break
            }
        }
    }
}

/// The tree, JSONPath matches, or nodes whose key or value contains the query.
private struct JSONSearchResults: View {
    let root: JSONNode
    let query: String

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            Section { JSONRootRows(root: root) }
        } else if q.hasPrefix("$") {
            switch Result(catching: { try JSONPath(q).evaluate(root) }) {
            case .success(let matches): rows(matches.map { ($0.path, $0.node) })
            case .failure(let error): Section { Text("\(error)").font(.app(.caption)).foregroundStyle(.statusError) }
            }
        } else {
            rows(Self.find(q.lowercased(), in: root, path: "$"))
        }
    }

    @ViewBuilder private func rows(_ matches: [(path: String, node: JSONNode)]) -> some View {
        Section {
            ForEach(Array(matches.prefix(JSONNodeRow.maxChildren).enumerated()), id: \.element.path) { _, match in
                JSONNodeRow(label: match.path, path: match.path, node: match.node, depth: 2, stacked: true)
            }
        } header: {
            Text(matches.count == 1 ? "1 match" : "\(matches.count) matches")
        }
    }

    /// Leaves and members whose key or printed value contains `q`, in document order.
    static func find(_ q: String, in node: JSONNode, path: String, depth: Int = 0) -> [(path: String, node: JSONNode)] {
        guard depth < JSONNode.maxDepth else { return [] }
        switch node {
        case .object(let members):
            return members.flatMap { m -> [(path: String, node: JSONNode)] in
                let p = "\(path).\(m.key)"
                if m.key.lowercased().contains(q) { return [(p, m.value)] }
                return find(q, in: m.value, path: p, depth: depth + 1)
            }
        case .array(let items):
            return items.enumerated().flatMap { find(q, in: $1, path: "\(path)[\($0)]", depth: depth + 1) }
        case .string(let s): return s.lowercased().contains(q) ? [(path, node)] : []
        case .number(let n): return n.contains(q) ? [(path, node)] : []
        case .bool(let b): return String(b).contains(q) ? [(path, node)] : []
        case .null: return "null".contains(q) ? [(path, node)] : []
        }
    }
}

enum HexDump {
    /// The viewer shows this much of a binary body as hex.
    static let maxViewerBytes = 1024 * 1024

    /// `offset  16 hex bytes  ascii`, one line per 16 bytes.
    static func text(_ data: Data) -> String {
        let bytes = [UInt8](data)
        return stride(from: 0, to: bytes.count, by: 16).map { offset in
            let row = bytes[offset..<min(offset + 16, bytes.count)]
            let hex = row.map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii = String(row.map { (0x20..<0x7f).contains($0) ? Character(UnicodeScalar($0)) : "." })
            return String(format: "%08x  ", offset) + hex.padding(toLength: 47, withPad: " ", startingAt: 0) + "  " + ascii
        }.joined(separator: "\n")
    }
}
