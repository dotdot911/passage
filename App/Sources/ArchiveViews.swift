import ProxyModel
import Storage
import SwiftUI
import UniformTypeIdentifiers
import Viewing

extension UTType {
    static let har = UTType(importedAs: "com.passage.io.har", conformingTo: .json)
    static let charlesSession = UTType(importedAs: "com.passage.io.chlsj", conformingTo: .json)
    static let yaml = UTType(filenameExtension: "yaml") ?? .plainText
}

/// The system share sheet for one file.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// The Traffic tab's "…" menu: sessions, import and export of the whole list.
struct TrafficArchiveMenu: View {
    @Environment(AppModel.self) private var model
    @Binding var showSessions: Bool
    @Binding var showImporter: Bool
    @Binding var savingSession: Bool
    @Binding var confirmClear: Bool
    /// Starts Select mode; nil when the list on screen cannot select.
    var select: (() -> Void)?

    var body: some View {
        Menu {
            if let select {
                Button("Select", action: select)
            }
            Section {
                Button("Save Session…") { savingSession = true }
                Button("Sessions…") { showSessions = true }
            }
            Section {
                Button("Import HAR or Charles Session…") { showImporter = true }
                Menu {
                    ForEach(ArchiveFormat.allCases) { format in
                        Button(format.rawValue) {
                            Task { await model.share(await model.flowsForExport(), as: format, name: "Passage") }
                        }
                    }
                } label: { Text("Export") }
            }
            Section {
                Button("Clear Traffic", role: .destructive) { confirmClear = true }
                    .disabled(model.flows.isEmpty && model.domains.isEmpty)
            }
        } label: { Image(symbol: .moreHoriz) }
        .disabled(model.activity != nil)
        .accessibilityLabel("More")
    }
}

/// Saved sessions: tap to import into the list, swipe to delete, share or rename.
struct SessionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager
    @State private var sessions: [SavedSession] = []
    @State private var renaming: SavedSession?
    @State private var newName = ""
    /// The root view cannot present the share sheet over this sheet, so it is presented here.
    @State private var sharing: SharedFile?
    @State private var renameError: String?

    var body: some View {
        NavigationStack {
            AppList {
                ForEach(sessions) { session in
                    Button {
                        dismiss()
                        Task { await model.importArchive(from: session.url) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.name).font(.app(.body))
                            Text("\(session.modified.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: Int64(session.size), countStyle: .file))")
                                .font(.app(.caption)).foregroundStyle(.secondary)
                        }
                    }
                    .tint(.primary)
                    .contextMenu {
                        Button("Rename…") { newName = session.name; renaming = session }
                        ShareLink(item: session.url) { Text("Share") }
                        Button("Delete", role: .destructive) { model.deleteSession(session, undoManager: undoManager); refresh() }
                    }
                    .swipeActions {
                        SwipeAction("Delete", symbol: .delete, color: .statusError, role: .destructive) {
                            model.deleteSession(session, undoManager: undoManager); refresh()
                        }
                        SwipeAction("Share", symbol: .iosShare) { sharing = SharedFile(url: session.url) }
                    }
                }
            }
            .overlay {
                if sessions.isEmpty {
                    ContentUnavailableView("No Saved Sessions", symbol: .inbox,
                                           description: Text("Use Save Session to keep the current traffic as a HAR file."))
                }
            }
            .alert("Couldn’t Rename Session", isPresented: Binding(get: { renameError != nil }, set: { if !$0 { renameError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(renameError ?? "") }
            .sheet(item: $sharing) { ShareSheet(items: $0.items).ignoresSafeArea().presentationDetents([.medium, .large]) }
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { CloseButton { dismiss() } } }
            .alert("Rename Session", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Rename") {
                    if let renaming { renameError = model.renameSession(renaming, to: newName) }
                    refresh()
                }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel", role: .cancel) {}
            }
            .onAppear(perform: refresh)
            .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange)) { _ in refresh() }
        }
    }

    private func refresh() { sessions = model.sessions() }
}

/// Asks for a session name, defaulting to the date and time.
struct SaveSessionAlert: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var isPresented: Bool
    @State private var name = ""

    func body(content: Content) -> some View {
        content.alert("Save Session", isPresented: $isPresented) {
            TextField("Name", text: $name)
            Button("Save") { Task { await model.saveSession(named: name) } }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves all HTTP and HTTPS requests as a HAR file. You can also find it in the Files app.")
        }
        .onChange(of: isPresented) {
            if isPresented { name = "Session \(Date().formatted(date: .abbreviated, time: .shortened))" }
        }
    }
}

/// Share ▸ entries for one flow.
struct FlowShareMenu: View {
    @Environment(AppModel.self) private var model
    let flow: FlowRecord

    var body: some View {
        Menu {
            ForEach(ArchiveFormat.allCases) { format in
                Button(format.rawValue) { Task { await model.share([flow], as: format, name: flow.host) } }
            }
            Button("cURL") {
                Task {
                    let request = await model.composedRequest(for: flow)
                    model.shareText(CodeGenerator.generate(request, language: .curl))
                }
            }
            Button("Raw Request and Response") {
                Task { model.shareText(await model.rawExchange(flow)) }
            }
        } label: { Label("Share", symbol: .iosShare) }
        .menuOrder(.fixed)
    }
}
