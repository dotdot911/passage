import Foundation

/// A script rule's code, as handed to the runner.
public struct ScriptSource: Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var code: String
    public init(id: UUID, name: String, code: String) {
        self.id = id
        self.name = name
        self.code = code
    }
}

/// A request or response as a script sees it. `body` is the raw body as on the wire (possibly compressed).
public struct ScriptMessage: Equatable, Sendable {
    public var method: String
    public var url: String
    /// Response status; nil for a request.
    public var status: Int?
    public var headers: [HeaderField]
    public var body: Data

    public init(method: String = "", url: String = "", status: Int? = nil, headers: [HeaderField], body: Data) {
        self.method = method
        self.url = url
        self.status = status
        self.headers = headers
        self.body = body
    }
}

public enum ScriptOutcome: Equatable, Sendable {
    case unchanged
    /// The edited request (request phase) or response (response phase). When the body was changed it is
    /// sent uncompressed and the framing headers (Content-Encoding, Content-Length, Transfer-Encoding) are gone.
    case modified(ScriptMessage)
    /// A response that answers the request without reaching the server (request phase only).
    case respond(ScriptMessage)
    case abort
    case failed(String)
}

public enum ScriptPhase: String, Codable, Sendable { case request, response }

/// One `console.*` line or error from a script.
public struct ScriptLog: Codable, Equatable, Sendable {
    public enum Level: String, Codable, Sendable { case log, info, warn, error }
    public var level: Level
    public var message: String
    public var scriptName: String
    public var date: Date

    public init(level: Level, message: String, scriptName: String, date: Date = Date()) {
        self.level = level
        self.message = message
        self.scriptName = scriptName
        self.date = date
    }
}

/// Runs scripts for the engine. Implemented by `Scripting.ScriptRunner`, so the engine does not link JavaScriptCore.
public protocol ScriptHost: Sendable {
    /// - Parameter completion: called once, on any thread.
    func run(scriptID: UUID, phase: ScriptPhase, flowID: UUID, request: ScriptMessage, response: ScriptMessage?,
             completion: @escaping @Sendable (ScriptOutcome) -> Void)
}
