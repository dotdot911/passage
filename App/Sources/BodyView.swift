import ProxyModel
import Storage
import SwiftUI
import Viewing

enum BodyMode: String, CaseIterable { case auto = "Auto", text = "Text", hex = "Hex" }

/// A stored body for the detail screen, held above the List so scrolling a row away never resets it.
enum BodyLoad: Sendable {
    case loading
    case empty
    case loaded(LoadedBody)

    static func load(bodies: BodyStore?, flowID: UUID, side: BodySide, headers: [HeaderField]) async -> BodyLoad {
        await Task.detached(priority: .userInitiated) { () -> BodyLoad in
            guard let prefix = bodies?.readPrefix(flowID: flowID, side: side, maxBytes: BodyPreview.maxRawBytes),
                  !prefix.data.isEmpty else { return .empty }
            return .loaded(LoadedBody(BodyPreview(raw: prefix.data, storedSize: prefix.totalSize, headers: headers)))
        }.value
    }
}

/// A preview with its inline text already cut into List rows; built off the main thread.
struct LoadedBody: Sendable {
    let preview: BodyPreview
    let text: TextChunks
    let parts: [LoadedBody]

    init(_ preview: BodyPreview) {
        self.preview = preview
        text = TextChunks(preview)
        parts = preview.partPreviews.map(LoadedBody.init)
    }
}

/// Text split into small pieces, one List row each, so no single cell has to measure 64 KB of text.
struct TextChunks: Sendable {
    static let maxLines = 40
    static let maxCharacters = 2048

    let chunks: [String]
    /// The text was cut at `BodyPreview.maxInlineTextBytes`; the rest is in the full-text viewer.
    let truncated: Bool

    init(_ preview: BodyPreview) {
        if preview.inlineText.isEmpty, preview.json != nil {
            let full = preview.fullText()
            self.init(String(full.prefix(BodyPreview.maxInlineTextBytes)), truncated: full.count > BodyPreview.maxInlineTextBytes)
        } else {
            self.init(preview.inlineText, truncated: preview.inlineTextTruncated)
        }
    }

    init(_ text: String, truncated: Bool) {
        chunks = Self.split(text)
        self.truncated = truncated
    }

    /// Groups whole lines up to `maxLines` or `maxCharacters`; a longer line becomes several pieces.
    static func split(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var chunks: [String] = []
        var current = ""
        var lines = 0
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var rest = line[...]
            repeat {
                let piece = rest.prefix(maxCharacters)
                rest = rest.dropFirst(piece.count)
                if lines > 0, lines >= maxLines || current.count + piece.count > maxCharacters {
                    chunks.append(current)
                    current = ""
                    lines = 0
                }
                if lines > 0 { current += "\n" }
                current += piece
                lines += 1
            } while !rest.isEmpty
        }
        if lines > 0 { chunks.append(current) }
        return chunks
    }
}

/// Monospaced text chunks as consecutive rows that read as one block.
struct TextChunkRows: View {
    let chunks: [String]
    var font: Font = .mono(.caption)

    var body: some View {
        ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in
            Text(chunk)
                .font(font)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        }
    }
}

/// A loaded body (or its loading and empty states) as List sections.
struct BodySection: View {
    let load: BodyLoad

    var body: some View {
        switch load {
        case .loading:
            Section("Body") { ProgressView() }
        case .empty:
            Section("Body") { Text("No body").foregroundStyle(.secondary) }
        case .loaded(let loaded):
            BodyContent(loaded: loaded, title: "Body")
        }
    }

    static func load(bodies: BodyStore?, flowID: UUID, side: BodySide, headers: [HeaderField], maxBytes: Int) async -> BodyPreview? {
        await Task.detached(priority: .userInitiated) { () -> BodyPreview? in
            guard let prefix = bodies?.readPrefix(flowID: flowID, side: side, maxBytes: maxBytes),
                  !prefix.data.isEmpty else { return nil }
            return BodyPreview(raw: prefix.data, storedSize: prefix.totalSize, headers: headers)
        }.value
    }
}

/// A decoded body as List sections: mode picker, summary and the chosen previewer.
struct BodyContent: View {
    let loaded: LoadedBody
    let title: String
    @State private var mode = BodyMode.auto

    private var preview: BodyPreview { loaded.preview }

    var body: some View {
        Section {
            if let summary = preview.summary {
                Text(summary).font(.app(.caption)).foregroundStyle(preview.decoded.error == nil ? Color.secondary : Color.orange)
            }
        } header: {
            HStack {
                Text([title, preview.kind.title, RequestTabSize.text(preview.storedSize)].joined(separator: " · "))
                Spacer()
                Menu {
                    Picker("View As", selection: $mode) {
                        ForEach(BodyMode.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    Button("Copy Body") { UIPasteboard.general.string = preview.fullText() }
                } label: { Image(symbol: .moreHoriz) }
                .headerControl()
                .accessibilityLabel("Body actions")
            }
        }
        switch mode {
        case .text: Section { TextPreview(loaded: loaded) }
        case .hex: Section { HexPreview(data: preview.decoded.data) }
        case .auto: BodyAutoPreview(loaded: loaded)
        }
        Section {
            NavigationLink { BodyViewer(loaded: loaded, title: title) } label: {
                Text("Open Body Viewer")
            }
        }
    }
}

struct BodyAutoPreview: View {
    let loaded: LoadedBody

    private var preview: BodyPreview { loaded.preview }

    var body: some View {
        switch preview.kind {
        case .json:
            if let node = preview.json { JSONSection(root: node) } else { Section { TextPreview(loaded: loaded) } }
        case .image(let format):
            Section { ImagePreview(data: preview.decoded.data, format: format) }
        case .html:
            HTMLSection(data: preview.decoded.data)
        case .form:
            Section { NameValueRows(pairs: preview.form) }
        case .multipart:
            MultipartSection(loaded: loaded)
        case .xml, .text:
            Section { TextPreview(loaded: loaded) }
        case .binary:
            BinaryWithProtobufSection(data: preview.decoded.data) { HexPreview(data: preview.decoded.data) }
        case .protobuf:
            ProtobufSection(messages: preview.protobuf)
        }
    }
}

/// The first 64 KB inline as chunk rows; the rest opens in the full-text viewer.
private struct TextPreview: View {
    let loaded: LoadedBody

    var body: some View {
        if loaded.text.chunks.isEmpty {
            Text("No text").font(.app(.caption)).foregroundStyle(.secondary)
        }
        TextChunkRows(chunks: loaded.text.chunks)
        if loaded.text.truncated {
            NavigationLink("Show Full Text") { BodyViewer(loaded: loaded, title: "Body", textMode: true) }
        }
    }
}

/// Built off the main thread; the first 64 KB only, in rows of 64 lines.
private struct HexPreview: View {
    nonisolated static let maxBytes = 64 * 1024
    nonisolated static let linesPerChunk = 64
    let data: Data
    @State private var chunks: [String]?

    var body: some View {
        if data.count > Self.maxBytes { Text("Showing the first 64 KB.").font(.app(.caption)).foregroundStyle(.secondary) }
        if let chunks {
            TextChunkRows(chunks: chunks, font: .mono(.caption2))
        } else {
            ProgressView().task(id: data.count) {
                let data = data
                chunks = await Task.detached { Self.hexChunks(data.prefix(Self.maxBytes)) }.value
            }
        }
    }

    nonisolated static func hexChunks(_ data: Data) -> [String] {
        let lines = hexDump(data).split(separator: "\n")
        return stride(from: 0, to: lines.count, by: linesPerChunk).map {
            lines[$0..<min($0 + linesPerChunk, lines.count)].joined(separator: "\n")
        }
    }

    /// `offset  16 hex bytes  ascii`, one line per 16 bytes.
    nonisolated static func hexDump(_ data: Data) -> String {
        let bytes = [UInt8](data)
        return HexDump.text(Data(bytes))
    }
}

/// Decoded off the main thread.
private struct ImagePreview: View {
    let data: Data
    let format: String
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                VStack(alignment: .leading) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 400)
                        .accessibilityLabel("\(format.uppercased()) image")
                    Text("\(format.uppercased()) · \(Int(image.size.width * image.scale))×\(Int(image.size.height * image.scale)) · "
                         + ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))
                        .font(.app(.caption)).foregroundStyle(.secondary)
                }
            } else if failed {
                Text("Can’t display this \(format.uppercased()) image.").foregroundStyle(.secondary)
            } else {
                ProgressView().task(id: data.count) {
                    let data = data
                    let decoded = await Task.detached { UIImage(data: data)?.preparingForDisplay() }.value
                    image = decoded
                    failed = decoded == nil
                }
            }
        }
    }
}

private struct MultipartSection: View {
    let loaded: LoadedBody

    private var preview: BodyPreview { loaded.preview }

    var body: some View {
        if let multipart = preview.multipart {
            if multipart.incomplete {
                Section { Text("The closing boundary is missing, so the body may be cut off.").font(.app(.caption)).foregroundStyle(.statusWarning) }
            }
            ForEach(Array(zip(multipart.parts, loaded.parts).enumerated()), id: \.offset) { index, pair in
                let (part, partLoaded) = pair
                Section("Part \(index + 1)" + (part.name.map { " · \($0)" } ?? "") + (part.filename.map { " · \($0)" } ?? "")) {
                    NameValueRows(pairs: part.headers.map { ($0.name, $0.value) })
                }
                if case .multipart = partLoaded.preview.kind {
                    Section { TextPreview(loaded: partLoaded) }
                } else {
                    BodyAutoPreview(loaded: partLoaded)
                }
            }
        }
    }
}

struct ReadOnlyTextView: UIViewRepresentable {
    let text: String
    /// Bump to open the find bar, searching for `findQuery`.
    var findRequest = 0
    var findQuery = ""

    final class Coordinator { var findRequest = 0 }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isFindInteractionEnabled = true
        view.font = .mono(.footnote)
        view.backgroundColor = Theme.current.palette.ground
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
        if findRequest != context.coordinator.findRequest {
            context.coordinator.findRequest = findRequest
            // Text set after presenting only fills the field; set before, presenting runs the search.
            if !findQuery.isEmpty { view.findInteraction?.searchText = findQuery }
            view.findInteraction?.presentFindNavigator(showingReplace: false)
        }
    }
}

extension BodyKind {
    /// "JSON", "PNG", "HTML"…, for the body's section header.
    var title: String {
        switch self {
        case .json: "JSON"
        case .image(let format): format.uppercased()
        case .html: "HTML"
        case .form: "Form"
        case .multipart: "Multipart"
        case .xml: "XML"
        case .text: "Text"
        case .binary: "Binary"
        case .protobuf: "Protobuf"
        }
    }
}

enum RequestTabSize {
    /// "0 B", "429 B", "12 KB".
    static func text(_ n: Int) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: Int64(n))
    }
}

extension View {
    /// Gives a small control in a section header the 44-point hit area HIG asks for, without making the header taller.
    func headerControl() -> some View {
        frame(minWidth: 44, minHeight: 44, alignment: .trailing)
            .contentShape(Rectangle())
            .padding(.vertical, -12)
    }
}

extension View {
    /// A Done button above the keyboard, for number pads and multi-line fields that have no return key to finish with.
    func keyboardDoneButton() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
    }
}

/// Pretty-prints or minifies JSON text for the body editors.
enum JSONFormatter {
    /// The reformatted text, or nil when `text` is not valid JSON.
    static func format(_ text: String, pretty: Bool) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]),
              let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
                                                                     : [.withoutEscapingSlashes, .fragmentsAllowed])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
