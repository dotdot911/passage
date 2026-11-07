import ProxyModel
import Storage
import SwiftUI
import Viewing

/// Compares two flows: first line, headers and body (line by line, JSON pretty-printed first).
struct DiffView: View {
    @Environment(AppModel.self) private var model
    let a: FlowRecord
    let b: FlowRecord
    @State private var side = BodySide.response
    @State private var bodyDiff: (lines: [DiffLine], truncated: Bool)?

    /// Each side's body is read up to this size.
    static let maxBodyBytes = 1024 * 1024

    var body: some View {
        VStack(spacing: 0) {
            Picker("Side", selection: $side) {
                Text("Request").tag(BodySide.request)
                Text("Response").tag(BodySide.response)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal).padding(.vertical, 8)
            AppList(plain: true) {
                Section {
                    sideRow("A", a, color: .red)
                    sideRow("B", b, color: .green)
                }
                Section("First Line") {
                    let (x, y) = firstLines
                    if x == y {
                        Text(x).font(.mono(.caption))
                    } else {
                        DiffLineRow(line: DiffLine(.removed, x))
                        DiffLineRow(line: DiffLine(.added, y))
                    }
                }
                Section("Headers") {
                    let changes = TextDiff.headers(side == .request ? a.requestHeaders : a.responseHeaders,
                                                   side == .request ? b.requestHeaders : b.responseHeaders)
                    if changes.isEmpty { Text("None").foregroundStyle(.secondary) }
                    ForEach(Array(changes.enumerated()), id: \.offset) { _, change in HeaderChangeRow(change: change) }
                }
                Section {
                    if let bodyDiff {
                        if bodyDiff.truncated {
                            Text("Only the first \(TextDiff.maxLines) lines are compared.").font(.app(.caption)).foregroundStyle(.statusWarning)
                        }
                        CollapsedDiff(lines: bodyDiff.lines).id(side)
                    } else {
                        ProgressView()
                    }
                } header: { Text("Body") }
            }
            .listStyle(.plain)
        }
        .navigationTitle("Compare")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: side) { await loadBodies() }
    }

    /// "A  GET /json · 10:07:46", with the color its removed or added lines use.
    private func sideRow(_ label: String, _ flow: FlowRecord, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(symbol: .circleFill).font(.app(.caption2)).imageScale(.small).foregroundStyle(color).accessibilityHidden(true)
            Text(label).font(.mono(.caption).bold())
            Text("\(flow.methodText) \(flow.pathText) · \(flow.startedAt.formatted(.dateTime.hour().minute().second()))")
                .font(.mono(.caption)).lineLimit(1).truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }

    private var firstLines: (String, String) {
        func line(_ f: FlowRecord) -> String {
            side == .request ? "\(f.method ?? "") \(f.url ?? f.host)" : StatusBadge.text(f)
        }
        return (line(a), line(b))
    }

    private func loadBodies() async {
        bodyDiff = nil
        let bodies = model.store?.bodies
        let side = side
        let (ha, hb) = side == .request ? (a.requestHeaders, b.requestHeaders) : (a.responseHeaders, b.responseHeaders)
        async let pa = BodySection.load(bodies: bodies, flowID: a.id, side: side, headers: ha, maxBytes: Self.maxBodyBytes)
        async let pb = BodySection.load(bodies: bodies, flowID: b.id, side: side, headers: hb, maxBytes: Self.maxBodyBytes)
        let (x, y) = await (pa, pb)
        bodyDiff = await Task.detached { TextDiff.lines(x?.fullText() ?? "", y?.fullText() ?? "") }.value
    }
}

/// Runs of more than 6 unchanged lines fold into one tappable row.
private struct CollapsedDiff: View {
    let lines: [DiffLine]
    @State private var expanded: Set<Int> = []

    enum Chunk: Identifiable {
        case line(Int, DiffLine)
        case folded(start: Int, count: Int)
        var id: Int { switch self { case .line(let i, _): i; case .folded(let s, _): -s - 1 } }
    }

    var body: some View {
        if lines.allSatisfy({ $0.kind == .same }) {
            Text("The bodies are identical.").foregroundStyle(.secondary)
        }
        ForEach(chunks) { chunk in
            switch chunk {
            case .line(_, let line): DiffLineRow(line: line)
            case .folded(let start, let count):
                Button("… ^[\(count) unchanged line](inflect: true)") { expanded.insert(start) }
                    .font(.app(.caption)).foregroundStyle(.secondary)
            }
        }
    }

    private var chunks: [Chunk] {
        var out: [Chunk] = []
        var i = 0
        while i < lines.count {
            if lines[i].kind == .same {
                var j = i
                while j < lines.count && lines[j].kind == .same { j += 1 }
                let run = j - i
                if run > 6 && !expanded.contains(i) {
                    for k in i..<i + 3 { out.append(.line(k, lines[k])) }
                    out.append(.folded(start: i, count: run - 6))
                    for k in j - 3..<j { out.append(.line(k, lines[k])) }
                } else {
                    for k in i..<j { out.append(.line(k, lines[k])) }
                }
                i = j
            } else {
                out.append(.line(i, lines[i]))
                i += 1
            }
        }
        return out
    }
}

private struct DiffLineRow: View {
    let line: DiffLine

    var body: some View {
        let (sign, color): (String, Color) = switch line.kind {
        case .same: (" ", .clear)
        case .added: ("+", .green)
        case .removed: ("-", .red)
        }
        Text("\(sign) \(line.text)")
            .font(.mono(.caption))
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowBackground(color.opacity(0.15))
            .textSelection(.enabled)
            .accessibilityLabel("\(line.kind == .added ? "Added" : line.kind == .removed ? "Removed" : "Unchanged"): \(line.text)")
    }
}

private struct HeaderChangeRow: View {
    let change: HeaderChange

    var body: some View {
        switch change {
        case .same(let name, let value): DiffLineRow(line: DiffLine(.same, "\(name): \(value)"))
        case .added(let name, let value): DiffLineRow(line: DiffLine(.added, "\(name): \(value)"))
        case .removed(let name, let value): DiffLineRow(line: DiffLine(.removed, "\(name): \(value)"))
        case .changed(let name, let old, let new):
            DiffLineRow(line: DiffLine(.removed, "\(name): \(old)"))
            DiffLineRow(line: DiffLine(.added, "\(name): \(new)"))
        }
    }
}
