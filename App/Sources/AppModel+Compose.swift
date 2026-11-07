import Foundation
import IPC
import ProxyModel
import Storage

/// A screen pushed on the Compose tab.
enum ComposeRoute: Hashable {
    case editor, history, collection(UUID)
}

/// One editable header row in Compose.
struct EditableHeader: Identifiable, Hashable {
    var id = UUID()
    var name: String
    var value: String
    var enabled = true
}

/// The Compose form. A body that is not valid UTF-8 cannot be edited, only kept or cleared.
struct ComposeDraft: Hashable {
    static let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

    var method = "GET"
    var url = ""
    var headers: [EditableHeader] = []
    var bodyText = ""
    var binaryBody: Data?

    init() {}

    /// Nothing typed yet, so replacing it loses nothing.
    var isBlank: Bool { url.isEmpty && bodyText.isEmpty && binaryBody == nil && headers.isEmpty }

    init(_ request: ComposedRequest) {
        method = request.method.uppercased()
        url = request.url
        headers = request.headers.map { EditableHeader(name: $0.name, value: $0.value) }
        if let body = request.body {
            if let text = String(data: body, encoding: .utf8) { bodyText = text } else { binaryBody = body }
        }
    }

    var request: ComposedRequest {
        let body = binaryBody ?? (bodyText.isEmpty ? nil : Data(bodyText.utf8))
        let fields = headers.filter { $0.enabled && !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { HeaderField(name: $0.name.trimmingCharacters(in: .whitespaces), value: $0.value) }
        return ComposedRequest(method: method, url: url.trimmingCharacters(in: .whitespaces), headers: fields, body: body)
    }

    /// Why the draft cannot be sent, or nil.
    var urlProblem: String? {
        if url.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a URL." }
        do { _ = try request.target(); return nil } catch { return error.description }
    }
}

extension AppModel {
    /// Edit & Repeat reads at most this much of a stored request body.
    nonisolated static let maxEditableBody = 10 * 1024 * 1024

    /// Whether Repeat, Edit & Repeat and Copy as… make sense for a flow.
    func canResend(_ flow: FlowRecord) -> Bool {
        (flow.kind == .http || flow.kind == .https) && !flow.isEncryptedTunnel && flow.method != nil && flow.url != nil
    }

    /// The flow's request with its body (up to `maxEditableBody`), read off the main thread.
    func composedRequest(for flow: FlowRecord) async -> ComposedRequest {
        let bodies = store?.bodies
        let body = await Task.detached(priority: .userInitiated) {
            bodies?.readPrefix(flowID: flow.id, side: .request, maxBytes: Self.maxEditableBody)?.data
        }.value
        return ComposedRequest(flow: flow, body: body)
    }

    /// Pushes an editor with the flow's request over the screen it was opened from.
    func editAndRepeat(_ flow: FlowRecord) async {
        let draft = ComposeDraft(await composedRequest(for: flow))
        tab = .traffic
        path.append(.compose(draft))
    }

    /// Sends the flow's request again, byte for byte (the whole stored body is reused), and stays on the current screen.
    /// The new flow is remembered in `repeats` so the detail screen can show its result.
    /// - Returns: an error message, or nil once the request is on its way.
    func repeatFlow(_ flow: FlowRecord) async -> String? {
        var request = ComposedRequest(flow: flow, body: nil)
        request.body = nil
        switch await dispatch(request, copyingBodyOf: flow.id) {
        case .success(let copy):
            repeats[flow.id] = copy.id
            return nil
        case .failure(let error):
            return error.message
        }
    }

    /// Sends a composed request through the tunnel extension and opens its flow.
    /// - Parameter source: reuse this flow's stored request body instead of `request.body`.
    /// - Returns: an error message, or nil once the request is on its way.
    func send(_ request: ComposedRequest, copyingBodyOf source: UUID? = nil) async -> String? {
        switch await dispatch(request, copyingBodyOf: source) {
        case .success(let flow):
            open(flow)
            return nil
        case .failure(let error):
            return error.message
        }
    }

    struct SendError: Error { let message: String }

    /// Sends a composed request through the tunnel extension and starts watching its flow.
    /// - Returns: the flow as recorded so far, or why it could not be sent.
    func dispatch(_ request: ComposedRequest, copyingBodyOf source: UUID? = nil) async -> Result<FlowRecord, SendError> {
        guard let store else { return .failure(SendError(message: "The traffic database isn’t available.")) }
        guard tunnel.isRunning else { return .failure(SendError(message: "The proxy is off. Turn it on to send requests.")) }
        let target: ComposedRequest.Target
        do { target = try request.target() } catch { return .failure(SendError(message: error.description)) }

        let id = UUID()
        let file = store.bodies.url(flowID: id, side: .request)
        let body = request.body
        let copied = await Task.detached(priority: .userInitiated) { () -> Data? in
            if let source {
                let from = store.bodies.url(flowID: source, side: .request)
                guard FileManager.default.fileExists(atPath: from.path) else { return nil }
                try? FileManager.default.copyItem(at: from, to: file)
                return try? Data(contentsOf: file, options: .mappedIfSafe)
            }
            if let body { try? body.write(to: file) }
            return body
        }.value

        var history = request
        history.body = copied
        try? store.addComposeHistory(history)

        var message = request
        message.body = nil
        switch await tunnel.send(.send(flowID: id, request: message)) {
        case .ok?:
            var placeholder = FlowRecord(id: id, kind: target.isHTTPS ? .https : .http, host: target.host, ip: "", port: target.port)
            placeholder.method = request.method.uppercased()
            placeholder.url = request.url
            placeholder.requestHeaders = request.wireHeaders(target: target, bodyLength: copied?.count ?? 0)
            placeholder.note = "Sent from Compose"
            watch(placeholder)
            return .success(placeholder)
        case .error(let text)?:
            return .failure(SendError(message: text))
        default:
            return .failure(SendError(message: "The proxy extension didn’t respond. Make sure the proxy is on, then try again."))
        }
    }
}
