import Foundation
import ProxyModel
import Rules
import Scripting
import Storage
import Viewing

/// Starting points offered by the + menu of Scripting.
enum ScriptTemplate: String, CaseIterable, Identifiable {
    case blank, addHeader, editJSON, mock, hmac, saveToken

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blank: "Blank"
        case .addHeader: "Add Header"
        case .editJSON: "Edit JSON Response"
        case .mock: "Mock Response"
        case .hmac: "Sign with HMAC"
        case .saveToken: "Save Token to $shared"
        }
    }

    /// Which phases the template needs.
    var action: RuleAction {
        switch self {
        case .blank, .saveToken: .script(request: true, response: true)
        case .addHeader, .mock, .hmac: .script(request: true, response: false)
        case .editJSON: .script(request: false, response: true)
        }
    }

    var code: String {
        switch self {
        case .blank: """
            // Called once for the request (flow.phase == "request") and once for the response.
            function handle(flow) {
              if (flow.phase === "request") {
                // flow.request.headers["X-Debug"] = "1";
              } else {
                console.log(flow.response.status, flow.request.url);
              }
            }

            """
        case .addHeader: """
            function handle(flow) {
              flow.request.headers["X-Debug"] = "1";
              delete flow.request.headers["If-None-Match"];
            }

            """
        case .editJSON: """
            function handle(flow) {
              const json = JSON.parse(flow.response.body);
              json.debug = true;
              flow.response.body = json; // objects are sent as JSON
            }

            """
        case .mock: """
            function handle(flow) {
              flow.response = {
                status: 200,
                headers: { "Content-Type": "application/json" },
                body: { ok: true, mocked: new Date().toISOString() },
              };
            }

            """
        case .hmac: """
            const SECRET = "change-me";

            function handle(flow) {
              const timestamp = String(Math.floor(Date.now() / 1000));
              const payload = flow.request.method + "\\n" + flow.request.url + "\\n" + timestamp + "\\n" + (flow.request.body || "");
              flow.request.headers["X-Timestamp"] = timestamp;
              flow.request.headers["X-Signature"] = crypto.hmac("sha256", SECRET, payload);
            }

            """
        case .saveToken: """
            // Saves the token from a login response and adds it to later requests.
            function handle(flow) {
              if (flow.phase === "response" && flow.request.url.includes("/login")) {
                const json = JSON.parse(flow.response.body || "{}");
                if (json.token) $shared.token = json.token;
              } else if (flow.phase === "request" && $shared.token) {
                flow.request.headers["Authorization"] = "Bearer " + $shared.token;
              }
            }

            """
        }
    }
}

/// What "Run with Flow…" produced for one phase.
struct ScriptPhaseResult: Identifiable {
    let phase: ScriptPhase
    let outcome: ScriptOutcome
    /// The message after the script, nil when it was aborted or failed.
    let message: ScriptMessage?
    var id: ScriptPhase { phase }
}

struct ScriptTestResult {
    var phases: [ScriptPhaseResult] = []
    var logs: [ScriptLog] = []
}

private final class LogCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ScriptLog] = []
    func add(_ log: ScriptLog) { lock.withLock { items.append(log) } }
    var all: [ScriptLog] { lock.withLock { items } }
}

extension AppModel {
    static let maxScriptLogs = 500

    func appendScriptLogs(_ logs: [ScriptLog]) {
        scriptLogs.append(contentsOf: logs)
        if scriptLogs.count > Self.maxScriptLogs { scriptLogs.removeFirst(scriptLogs.count - Self.maxScriptLogs) }
    }

    /// - Returns: the tunnel's error, or nil. The Console can sit inside the script editor's sheet, so it shows the error.
    func resetScriptState() async -> String? {
        if case .error(let message)? = await tunnel.send(.resetScriptState) { return message }
        return nil
    }

    /// The most recorded flows `flows(matching:)` returns.
    static let maxMatches = 100

    /// Recent flows a rule with `match` would apply to, newest first.
    /// - Parameter byHost: match only the host, as the tunnel does for host-level tools (DNS, throttling, Allow List).
    func flows(matching match: URLMatch, byHost: Bool = false) async -> [FlowRecord] {
        guard let store, let compiled = try? CompiledMatch(match) else { return [] }
        let limit = Self.maxMatches
        return await Task.detached(priority: .userInitiated) {
            let all = (try? store.flows(.allHTTP, limit: 1000)) ?? []
            return Array(all.filter { f in
                if byHost {
                    let origin = "\(f.kind == .http ? "http" : "https")://\(f.host)"
                    return compiled.matches(url: origin, method: nil) || compiled.matches(url: origin + "/", method: nil)
                }
                return f.url.map { compiled.matches(url: $0, method: f.method) } ?? false
            }.prefix(limit))
        }.value
    }

    /// Runs `code` on a recorded flow in the app, as the tunnel would: the request phase, then the response phase
    /// with the request as the script left it. `$shared` starts empty.
    func testScript(_ code: String, name: String, action: RuleAction, on flow: FlowRecord) async -> ScriptTestResult {
        guard let store, case .script(let runRequest, let runResponse) = action else { return ScriptTestResult() }
        return await Task.detached(priority: .userInitiated) {
            let logs = LogCollector()
            let runner = ScriptRunner { logs.add($0) }
            let source = ScriptSource(id: UUID(), name: name, code: code)
            var request = ScriptMessage(method: flow.method ?? "GET", url: flow.url ?? "", headers: flow.requestHeaders,
                                        body: store.bodies.read(flowID: flow.id, side: .request) ?? Data())
            var result = ScriptTestResult()
            if runRequest {
                let outcome = runner.runOnce(source, phase: .request, flowID: flow.id, request: request, response: nil)
                switch outcome {
                case .modified(let m): request = m
                case .respond(let m):
                    result.phases.append(ScriptPhaseResult(phase: .request, outcome: outcome, message: m))
                    result.logs = logs.all
                    return result
                default: break
                }
                let shown: ScriptMessage? = switch outcome { case .abort, .failed: nil; default: request }
                result.phases.append(ScriptPhaseResult(phase: .request, outcome: outcome, message: shown))
                if case .abort = outcome { result.logs = logs.all; return result }
            }
            if runResponse, let status = flow.statusCode {
                let response = ScriptMessage(method: request.method, url: request.url, status: status, headers: flow.responseHeaders,
                                             body: store.bodies.read(flowID: flow.id, side: .response) ?? Data())
                let outcome = runner.runOnce(source, phase: .response, flowID: flow.id, request: request, response: response)
                let shown: ScriptMessage? = switch outcome {
                case .modified(let m): m
                case .unchanged: response
                default: nil
                }
                result.phases.append(ScriptPhaseResult(phase: .response, outcome: outcome, message: shown))
            }
            result.logs = logs.all
            return result
        }.value
    }
}

extension ScriptMessage {
    /// The body as text after undoing its Content-Encoding, or nil when it is not UTF-8.
    var bodyText: String? {
        String(data: BodyDecoder.decode(body, contentEncoding: headers.value(for: "Content-Encoding")).data, encoding: .utf8)
    }
}
