import Archive
import Foundation
import ProxyModel
import Storage
import Viewing

/// File formats a list of flows can be exported to.
enum ArchiveFormat: String, CaseIterable, Identifiable {
    case har = "HAR", charles = "Charles"
    var id: String { rawValue }
    var fileExtension: String { self == .har ? "har" : "chlsj" }
}

/// A file waiting in the share sheet.
/// What the share sheet offers: a file, or plain text such as a cURL command.
struct SharedFile: Identifiable {
    let id = UUID()
    let items: [Any]

    init(url: URL) { items = [url] }
    init(text: String) { items = [text] }
}

/// A saved session: a HAR file in Documents/Sessions.
struct SavedSession: Identifiable, Hashable {
    var url: URL
    var name: String { url.deletingPathExtension().lastPathComponent }
    var modified: Date
    var size: Int
    var id: URL { url }
}

extension AppModel {
    /// The most flows read for one export or saved session.
    nonisolated static let maxArchiveFlows = 20_000

    static var sessionsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Export

    /// Every flow matching the current filter and search (the whole list, not only one domain).
    func flowsForExport(host: String? = nil) async -> [FlowRecord] {
        guard let store else { return [] }
        let f = effectiveFilter(host: host)
        return await Task.detached { (try? store.flows(f, limit: Self.maxArchiveFlows)) ?? [] }.value.reversed()
    }

    /// Reads bodies, WebSocket messages and marks for `flows`, off the main thread.
    nonisolated static func archived(_ flows: [FlowRecord], store: FlowStore, marks: [UUID: FlowMark]) -> [ArchivedFlow] {
        flows.map { r in
            let raw = { (side: BodySide) in
                store.bodies.readPrefix(flowID: r.id, side: side, maxBytes: ArchivedFlow.maxExportBodyBytes * 4)?.data
            }
            let messages = r.statusCode == 101 ? ((try? store.webSocketMessages(flowID: r.id)) ?? []) : []
            return ArchivedFlow(record: r,
                                requestBody: ArchivedFlow.decodedBody(raw(.request), headers: r.requestHeaders),
                                responseBody: ArchivedFlow.decodedBody(raw(.response), headers: r.responseHeaders),
                                webSocketMessages: messages, comment: marks[r.id]?.comment, highlight: marks[r.id]?.color?.rawValue)
        }
    }

    /// Writes `flows` to a temporary file named after `name` and opens the share sheet.
    func share(_ flows: [FlowRecord], as format: ArchiveFormat, name: String) async {
        guard let store else { return }
        activity = "Exporting \(flows.count) request\(flows.count == 1 ? "" : "s")…"
        defer { activity = nil }
        let marks = self.marks
        let stamp = Self.fileStamp()
        let result = await Task.detached { () -> Result<URL, Error> in
            Result {
                let archived = Self.archived(flows, store: store, marks: marks)
                let data = format == .har ? try HAR.write(archived) : try Charles.write(archived)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(Self.safeFileName(name))-\(stamp).\(format.fileExtension)")
                try data.write(to: url, options: .atomic)
                return url
            }
        }.value
        switch result {
        case .success(let url): sharedFile = SharedFile(url: url)
        case .failure(let error): alert = AppAlert(title: "Couldn’t Export", message: error.localizedDescription)
        }
    }

    /// Shares one request as text: the raw HTTP exchange or a cURL command.
    func shareText(_ text: String) {
        sharedFile = SharedFile(text: text)
    }

    /// The request and response as HTTP/1.1 text, bodies decoded (binary bodies are summarised).
    func rawExchange(_ flow: FlowRecord) async -> String {
        guard let store else { return "" }
        let marks = self.marks
        let item = await Task.detached { Self.archived([flow], store: store, marks: marks)[0] }.value
        func body(_ data: Data?) -> String {
            guard let data, !data.isEmpty else { return "" }
            return "\n" + (String(data: data, encoding: .utf8) ?? "<\(data.count) bytes of binary data>")
        }
        let target = URLComponents(string: flow.url ?? "").map { ($0.percentEncodedPath.isEmpty ? "/" : $0.percentEncodedPath) + ($0.percentEncodedQuery.map { "?\($0)" } ?? "") } ?? "/"
        var lines = ["\(flow.method ?? "GET") \(target) \(flow.httpVersion ?? "HTTP/1.1")"]
        lines += flow.requestHeaders.map { "\($0.name): \($0.value)" }
        var text = lines.joined(separator: "\n") + "\n" + body(item.requestBody)
        if let status = flow.statusCode {
            var res = ["\(flow.httpVersion ?? "HTTP/1.1") \(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)"]
            res += flow.responseHeaders.map { "\($0.name): \($0.value)" }
            text += "\n\n" + res.joined(separator: "\n") + "\n" + body(item.responseBody)
        }
        return text
    }

    // MARK: Import

    /// Imports a HAR or Charles file into the list and switches to the Traffic tab.
    func importArchive(from url: URL) async {
        guard let store else { return }
        activity = "Importing…"
        defer { activity = nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        let result = await Task.detached { () -> Result<ImportResult, Error> in
            Result {
                let data = try Data(contentsOf: url)
                let parsed: ImportResult
                switch url.pathExtension.lowercased() {
                case "chlsj": parsed = try Charles.read(data)
                case "har": parsed = try HAR.read(data)
                default: parsed = try (try? HAR.read(data)) ?? Charles.read(data)
                }
                let flows = parsed.flows.map { $0.imported(from: name) }
                try Self.store(flows, in: store)
                return ImportResult(flows: flows, skipped: parsed.skipped)
            }
        }.value
        switch result {
        case .success(let r):
            tab = .traffic
            path = []
            filter.session = name
            reload()
            if r.skipped > 0 {
                alert = AppAlert(title: "Some Requests Were Skipped",
                                 message: "Imported \(r.flows.count) requests. \(r.skipped) couldn’t be read.")
            }
        case .failure(let error):
            alert = AppAlert(title: "Couldn’t Import File", message: error.localizedDescription)
        }
    }

    nonisolated static func store(_ flows: [ArchivedFlow], in store: FlowStore) throws {
        for f in flows {
            if let body = f.requestBody { try store.bodies.write(body, flowID: f.record.id, side: .request) }
            if let body = f.responseBody { try store.bodies.write(body, flowID: f.record.id, side: .response) }
        }
        try store.upsert(flows.map(\.record), messages: flows.flatMap(\.webSocketMessages))
        for f in flows where f.comment != nil || f.highlight != nil {
            try store.setMark(FlowMark(color: f.highlight.flatMap(MarkColor.init(rawValue:)), comment: f.comment), for: f.record.id)
        }
    }

    // MARK: Sessions

    func sessions() -> [SavedSession] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.sessionsDirectory, includingPropertiesForKeys: keys)) ?? []
        return files.filter { $0.pathExtension == "har" }.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return SavedSession(url: url, modified: values?.contentModificationDate ?? .distantPast, size: values?.fileSize ?? 0)
        }.sorted { $0.modified > $1.modified }
    }

    /// Saves every recorded HTTP and HTTPS flow (ignoring the filter) as a HAR file in Documents/Sessions.
    func saveSession(named name: String) async {
        guard let store else { return }
        activity = "Saving session…"
        defer { activity = nil }
        let marks = self.marks
        let url = Self.freeSessionURL(for: name)
        let result = await Task.detached { () -> Result<Int, Error> in
            Result {
                let flows = Array(try store.flows(.allHTTP, limit: Self.maxArchiveFlows).reversed())
                let archived = Self.archived(flows, store: store, marks: marks).filter(\.isExportable)
                try HAR.write(archived).write(to: url, options: .atomic)
                return archived.count
            }
        }.value
        switch result {
        case .success: break
        case .failure(let error): alert = AppAlert(title: "Couldn’t Save Session", message: error.localizedDescription)
        }
    }

    /// A session file named `name`, or "name 2", "name 3"… when that one is taken, so saving never overwrites.
    static func freeSessionURL(for name: String) -> URL {
        let base = safeFileName(name)
        var candidate = sessionsDirectory.appendingPathComponent("\(base).har")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = sessionsDirectory.appendingPathComponent("\(base) \(n).har")
            n += 1
        }
        return candidate
    }

    /// - Returns: why renaming failed, or nil. Sessions is a sheet, so it shows the error itself.
    @discardableResult
    func renameSession(_ session: SavedSession, to name: String) -> String? {
        guard Self.safeFileName(name) != session.url.deletingPathExtension().lastPathComponent else { return nil }
        let target = Self.freeSessionURL(for: name)
        do { try FileManager.default.moveItem(at: session.url, to: target) } catch { return error.localizedDescription }
        return nil
    }

    /// Moves the session file aside so Undo can bring it back; the system clears the temporary folder later.
    func deleteSession(_ session: SavedSession, undoManager: UndoManager? = nil) {
        let parked = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".har")
        guard (try? FileManager.default.moveItem(at: session.url, to: parked)) != nil else { return }
        undoManager?.registerUndo(withTarget: self) { _ in
            try? FileManager.default.moveItem(at: parked, to: session.url)
        }
        undoManager?.setActionName("Delete Session")
    }

    // MARK: OpenAPI

    /// - Returns: why the import failed, or nil.
    func importOpenAPI(from url: URL) async -> String? {
        guard let store else { return "The traffic database isn’t available." }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let result = await Task.detached { () -> Result<APICollection, Error> in
            Result {
                let collection = try OpenAPIImporter.importDocument(try Data(contentsOf: url), fileName: url.lastPathComponent)
                try store.saveAPICollection(collection)
                return collection
            }
        }.value
        if case .failure(let error) = result { return "\(error)" }
        return nil
    }

    func apiCollections() -> [APICollection] { (try? store?.apiCollections()) ?? [] }

    func deleteAPICollection(_ id: UUID) { try? store?.deleteAPICollection(id: id) }

    // MARK: Helpers

    nonisolated static func safeFileName(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Passage" : String(cleaned.prefix(80))
    }

    nonisolated static func fileStamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }
}
