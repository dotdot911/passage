import Crypto
import Foundation
import JavaScriptCore
import ProxyModel
import Viewing

/// Runs `handle(flow)` scripts on a private serial queue, one `JSContext` per script.
public final class ScriptRunner: ScriptHost, @unchecked Sendable {
    /// Larger bodies are not handed to scripts.
    public static let maxBodyBytes = 10 * 1024 * 1024
    /// Longest `console.*` line kept.
    static let maxLogBytes = 4096

    private let queue = DispatchQueue(label: "passage.scripts", qos: .userInitiated)
    private let timeout: TimeInterval
    private let onLog: @Sendable (ScriptLog) -> Void
    /// Everything below is confined to `queue`.
    private let vm = JSVirtualMachine()!
    private var sources: [UUID: ScriptSource] = [:]
    private var contexts: [UUID: (code: String, context: JSContext)] = [:]
    private var shared = "{}"
    private var timeLimitSet = false

    public init(timeout: TimeInterval = 2, onLog: @escaping @Sendable (ScriptLog) -> Void = { _ in }) {
        self.timeout = timeout
        self.onLog = onLog
    }

    /// Replaces the scripts; contexts of scripts whose code changed or that were removed are dropped.
    public func load(_ scripts: [ScriptSource]) {
        queue.async { [self] in
            sources = Dictionary(scripts.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
            contexts = contexts.filter { sources[$0.key]?.code == $0.value.code }
        }
    }

    /// Clears `$shared`.
    public func resetShared() { queue.async { [self] in shared = "{}" } }

    public func run(scriptID: UUID, phase: ScriptPhase, flowID: UUID, request: ScriptMessage, response: ScriptMessage?,
                    completion: @escaping @Sendable (ScriptOutcome) -> Void) {
        queue.async { [self] in
            completion(execute(scriptID: scriptID, phase: phase, flowID: flowID, request: request, response: response))
        }
    }

    /// Runs one script with code that is not loaded (the app's "Run with flow…"), blocking the caller.
    public func runOnce(_ source: ScriptSource, phase: ScriptPhase, flowID: UUID, request: ScriptMessage,
                        response: ScriptMessage?) -> ScriptOutcome {
        queue.sync {
            sources[source.id] = source
            if contexts[source.id]?.code != source.code { contexts[source.id] = nil }
            return execute(scriptID: source.id, phase: phase, flowID: flowID, request: request, response: response)
        }
    }

    // MARK: Execution (on `queue`)

    private func execute(scriptID: UUID, phase: ScriptPhase, flowID: UUID, request: ScriptMessage,
                         response: ScriptMessage?) -> ScriptOutcome {
        guard let source = sources[scriptID] else { return .failed("Script file is missing") }
        let outcome = evaluate(source, phase: phase, flowID: flowID, request: request, response: response)
        if case .failed(let message) = outcome { log(.error, message, source.name) }
        return outcome
    }

    private func evaluate(_ source: ScriptSource, phase: ScriptPhase, flowID: UUID, request: ScriptMessage,
                          response: ScriptMessage?) -> ScriptOutcome {
        let context: JSContext
        do { context = try self.context(for: source) } catch { return .failed(error.message) }
        let requestBody = Self.decoded(request)
        let responseBody = response.map(Self.decoded)
        var input: [String: Any] = ["phase": phase.rawValue, "id": flowID.uuidString, "request": Self.object(request)]
        if let response { input["response"] = Self.object(response) }

        let started = Date()
        var thrown: String?
        context.exceptionHandler = { _, exception in thrown = Self.describe(exception) }
        let result = context.objectForKeyedSubscript("__run").call(withArguments: [
            input, Bytes.make(requestBody, in: context), Bytes.make(responseBody ?? Data(), in: context), shared,
        ])
        context.exceptionHandler = nil
        if let thrown {
            let elapsed = Date().timeIntervalSince(started)
            if timeLimitSet, elapsed >= timeout * 0.9, thrown.contains("terminated") {
                return .failed("Script timed out after \(Self.seconds(timeout))")
            }
            return .failed(thrown)
        }
        guard let result, result.isObject else { return .failed("The script returned nothing") }
        if let s = result.objectForKeyedSubscript("shared"), s.isString { shared = s.toString() }
        if result.objectForKeyedSubscript("aborted").toBool() { return .abort }

        do {
            switch phase {
            case .request:
                if let res = result.objectForKeyedSubscript("response"), res.isObject {
                    let mock = try Self.message(res, original: nil, in: context, isResponse: true)
                    return .respond(mock)
                }
                let out = try Self.message(result.objectForKeyedSubscript("request"), original: request, in: context, isResponse: false)
                return out == request ? .unchanged : .modified(out)
            case .response:
                guard let response else { return .unchanged }
                guard let res = result.objectForKeyedSubscript("response"), res.isObject else {
                    return .failed("flow.response was removed")
                }
                let out = try Self.message(res, original: response, in: context, isResponse: true)
                return out == response ? .unchanged : .modified(out)
            }
        } catch {
            return .failed(error.message)
        }
    }

    private func context(for source: ScriptSource) throws(ScriptError) -> JSContext {
        if let cached = contexts[source.id], cached.code == source.code { return cached.context }
        guard let context = JSContext(virtualMachine: vm) else { throw ScriptError("Could not create a JavaScript context") }
        if !timeLimitSet { timeLimitSet = TimeLimit.set(timeout, on: context) }
        if !timeLimitSet { log(.warn, "Scripts run without a time limit on this system", source.name) }
        install(on: context, scriptName: source.name)
        var thrown: String?
        context.exceptionHandler = { _, exception in thrown = Self.describe(exception) }
        context.evaluateScript(prelude)
        if let thrown { throw ScriptError("Internal error: \(thrown)") }
        context.evaluateScript(source.code, withSourceURL: URL(string: "script.js"))
        context.exceptionHandler = nil
        if let thrown { throw ScriptError(thrown) }
        contexts[source.id] = (source.code, context)
        return context
    }

    /// The `__native` object the prelude wraps.
    private func install(on context: JSContext, scriptName: String) {
        let native = JSValue(newObjectIn: context)!
        let onLog = self.onLog
        let log: @convention(block) (String, String) -> Void = { level, message in
            onLog(ScriptLog(level: ScriptLog.Level(rawValue: level) ?? .log,
                            message: String(message.utf8.prefix(Self.maxLogBytes)) ?? message, scriptName: scriptName))
        }
        let utf8Encode: @convention(block) (String) -> JSValue = { s in
            Bytes.make(Data(s.utf8), in: JSContext.current())
        }
        let utf8Decode: @convention(block) (JSValue) -> JSValue = { v in
            guard let text = String(data: Bytes.read(v), encoding: .utf8) else { return JSValue(nullIn: JSContext.current()) }
            return JSValue(object: text, in: JSContext.current())
        }
        let base64Encode: @convention(block) (JSValue) -> String = { v in Bytes.read(v).base64EncodedString() }
        let base64Decode: @convention(block) (String) -> JSValue = { s in
            let context = JSContext.current()!
            var text = s.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            text += String(repeating: "=", count: (4 - text.count % 4) % 4)
            guard let data = Data(base64Encoded: text) else {
                context.exception = JSValue(newErrorFromMessage: "Invalid base64 string", in: context)
                return JSValue(undefinedIn: context)
            }
            return Bytes.make(data, in: context)
        }
        let hash: @convention(block) (String, JSValue) -> String = { alg, v in
            let data = Bytes.read(v)
            switch alg {
            case "md5": return Insecure.MD5.hash(data: data).hex
            case "sha1": return Insecure.SHA1.hash(data: data).hex
            case "sha512": return SHA512.hash(data: data).hex
            default: return SHA256.hash(data: data).hex
            }
        }
        let hmac: @convention(block) (String, JSValue, JSValue) -> JSValue = { alg, key, message in
            let context = JSContext.current()!
            let k = SymmetricKey(data: Bytes.read(key)), m = Bytes.read(message)
            let hex: String
            switch alg {
            case "sha1": hex = Data(HMAC<Insecure.SHA1>.authenticationCode(for: m, using: k)).hex
            case "sha256": hex = Data(HMAC<SHA256>.authenticationCode(for: m, using: k)).hex
            case "sha512": hex = Data(HMAC<SHA512>.authenticationCode(for: m, using: k)).hex
            default:
                context.exception = JSValue(newErrorFromMessage: "hmac: unsupported algorithm \"\(alg)\" (use sha1, sha256 or sha512)", in: context)
                return JSValue(undefinedIn: context)
            }
            return JSValue(object: hex, in: context)
        }
        native.setObject(log, forKeyedSubscript: "log" as NSString)
        native.setObject(utf8Encode, forKeyedSubscript: "utf8Encode" as NSString)
        native.setObject(utf8Decode, forKeyedSubscript: "utf8Decode" as NSString)
        native.setObject(base64Encode, forKeyedSubscript: "base64Encode" as NSString)
        native.setObject(base64Decode, forKeyedSubscript: "base64Decode" as NSString)
        native.setObject(hash, forKeyedSubscript: "hash" as NSString)
        native.setObject(hmac, forKeyedSubscript: "hmac" as NSString)
        context.setObject(native, forKeyedSubscript: "__native" as NSString)
    }

    private func log(_ level: ScriptLog.Level, _ message: String, _ scriptName: String) {
        onLog(ScriptLog(level: level, message: message, scriptName: scriptName))
    }

    // MARK: Conversion

    /// The body with its Content-Encoding undone (the raw bytes when that fails).
    static func decoded(_ m: ScriptMessage) -> Data {
        BodyDecoder.decode(m.body, contentEncoding: m.headers.value(for: "Content-Encoding")).data
    }

    static func object(_ m: ScriptMessage) -> [String: Any] {
        var o: [String: Any] = ["method": m.method, "url": m.url, "headers": m.headers.map { [$0.name, $0.value] }]
        if let status = m.status { o["status"] = status }
        return o
    }

    /// Reads a message the prelude exported. An unchanged body keeps `original`'s raw bytes and its framing headers.
    static func message(_ v: JSValue, original: ScriptMessage?, in context: JSContext, isResponse: Bool) throws(ScriptError) -> ScriptMessage {
        let pairs = (v.objectForKeyedSubscript("headers").toArray() as? [[Any]]) ?? []
        var headers = pairs.compactMap { p -> HeaderField? in
            guard p.count == 2, let n = p[0] as? String, let value = p[1] as? String else { return nil }
            return HeaderField(name: n, value: value)
        }
        // Untouched headers keep their original order and spelling (the header object merges repeats).
        if let original, !v.objectForKeyedSubscript("headersChanged").toBool() { headers = original.headers }
        let bodyChanged = v.objectForKeyedSubscript("bodyChanged").toBool()
        let body: Data
        if bodyChanged {
            body = Bytes.read(v.objectForKeyedSubscript("bytes"))
            let framing: Set<String> = ["content-encoding", "content-length", "transfer-encoding"]
            headers.removeAll { framing.contains($0.name.lowercased()) }
        } else {
            body = original?.body ?? Data()
        }
        guard body.count <= maxBodyBytes else { throw ScriptError("The body is larger than 10 MB") }
        var status: Int?
        if isResponse {
            let s = v.objectForKeyedSubscript("status")
            let n = s?.isNumber == true ? s!.toDouble() : Double(original?.status ?? 200)
            guard n == n.rounded(), (100...599).contains(n) else { throw ScriptError("Invalid status \(s?.toString() ?? "")") }
            status = Int(n)
        }
        let method = isResponse ? original?.method ?? "" : v.objectForKeyedSubscript("method").toString().uppercased()
        let url = isResponse ? original?.url ?? "" : v.objectForKeyedSubscript("url").toString() ?? ""
        if !isResponse {
            guard !(method ?? "").isEmpty else { throw ScriptError("flow.request.method is empty") }
            guard let c = URLComponents(string: url), ["http", "https"].contains(c.scheme?.lowercased() ?? ""), c.host?.isEmpty == false
            else { throw ScriptError("flow.request.url is not an http(s) URL: \(url)") }
        }
        return ScriptMessage(method: method ?? "", url: url, status: status, headers: headers, body: body)
    }

    static func describe(_ exception: JSValue?) -> String {
        guard let exception else { return "Unknown error" }
        let text = exception.toString() ?? "Unknown error"
        if let line = exception.objectForKeyedSubscript("line"), line.isNumber,
           exception.objectForKeyedSubscript("sourceURL")?.toString() == "script.js" {
            return "\(text) (line \(line.toInt32()))"
        }
        return text
    }

    static func seconds(_ t: TimeInterval) -> String {
        t == t.rounded() ? "\(Int(t)) s" : String(format: "%.1f s", t)
    }
}

struct ScriptError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

private extension Error {
    var message: String { (self as? ScriptError)?.message ?? "\(self)" }
}

private extension Sequence where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

private extension Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
