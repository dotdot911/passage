import Foundation
import ProxyModel
@testable import Scripting
import Testing

final class Logs: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ScriptLog] = []
    func add(_ l: ScriptLog) { lock.withLock { items.append(l) } }
    var all: [ScriptLog] { lock.withLock { items } }
}

@Suite struct ScriptRunnerTests {
    let logs = Logs()
    let request = ScriptMessage(method: "POST", url: "https://api.test/v1/items?q=1",
                                headers: [HeaderField(name: "Content-Type", value: "application/json"),
                                          HeaderField(name: "Cookie", value: "a=1"), HeaderField(name: "cookie", value: "b=2"),
                                          HeaderField(name: "Content-Length", value: "11")],
                                body: Data(#"{"count":1}"#.utf8))
    let response = ScriptMessage(status: 200, headers: [HeaderField(name: "Content-Type", value: "application/json")],
                                 body: Data(#"{"ok":true,"items":[1,2]}"#.utf8))

    func runner(timeout: TimeInterval = 2) -> ScriptRunner { ScriptRunner(timeout: timeout) { [logs] in logs.add($0) } }

    func run(_ code: String, phase: ScriptPhase = .request, runner: ScriptRunner? = nil, id: UUID = UUID(),
             request: ScriptMessage? = nil, response: ScriptMessage? = nil) -> ScriptOutcome {
        (runner ?? self.runner()).runOnce(ScriptSource(id: id, name: "test", code: code), phase: phase, flowID: UUID(),
                                          request: request ?? self.request,
                                          response: phase == .response ? (response ?? self.response) : nil)
    }

    @Test func untouchedFlowIsUnchanged() {
        #expect(run("function handle(flow) { const x = flow.request.body; }") == .unchanged)
        #expect(run("function handle(flow) { flow.response.headers }", phase: .response) == .unchanged)
    }

    @Test func readsTheRequest() {
        let code = """
        function handle(flow) {
          console.log(flow.phase, flow.request.method, flow.request.url, flow.request.headers["Content-Type"],
                      flow.request.headers.Cookie, JSON.parse(flow.request.body).count, flow.request.bodyBytes.length)
        }
        """
        #expect(run(code) == .unchanged)
        #expect(logs.all.map(\.message) == [#"request POST https://api.test/v1/items?q=1 application/json ["a=1","b=2"] 1 11"#])
    }

    @Test func editsHeadersAndJSONBody() {
        let code = """
        function handle(flow) {
          flow.request.headers["X-Token"] = "abc";
          delete flow.request.headers.Cookie;
          const body = JSON.parse(flow.request.body);
          body.count = 2;
          flow.request.body = body;
          flow.request.method = "put";
        }
        """
        guard case .modified(let m) = run(code) else { Issue.record("not modified"); return }
        #expect(m.method == "PUT")
        #expect(m.headers == [HeaderField(name: "Content-Type", value: "application/json"), HeaderField(name: "X-Token", value: "abc")])
        #expect(String(decoding: m.body, as: UTF8.self) == #"{"count":2}"#)
    }

    @Test func headerOnlyChangeKeepsTheRawBody() {
        let gz = ScriptMessage(status: 200, headers: [HeaderField(name: "Content-Encoding", value: "gzip")],
                               body: Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0xcb, 0x48, 0xcd, 0xc9, 0xc9,
                                           0x07, 0x00, 0x86, 0xa6, 0x10, 0x36, 0x05, 0x00, 0x00, 0x00]))
        let code = """
        function handle(flow) { console.log(flow.response.body); flow.response.headers["X-Seen"] = "1"; }
        """
        guard case .modified(let m) = run(code, phase: .response, response: gz) else { Issue.record("not modified"); return }
        #expect(logs.all.first?.message == "hello")
        #expect(m.body == gz.body)
        #expect(m.headers.value(for: "Content-Encoding") == "gzip")
    }

    @Test func bodyChangeDropsFraming() {
        let gz = ScriptMessage(status: 200, headers: [HeaderField(name: "Content-Encoding", value: "gzip"),
                                                      HeaderField(name: "Content-Length", value: "25")],
                               body: Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0xcb, 0x48, 0xcd, 0xc9, 0xc9,
                                           0x07, 0x00, 0x86, 0xa6, 0x10, 0x36, 0x05, 0x00, 0x00, 0x00]))
        guard case .modified(let m) = run("function handle(f) { f.response.body = f.response.body + '!'; f.response.status = 201 }",
                                          phase: .response, response: gz)
        else { Issue.record("not modified"); return }
        #expect(m.status == 201 && m.headers.isEmpty && m.body == Data("hello!".utf8))
    }

    @Test func bodyBytesWin() {
        guard case .modified(let m) = run("function handle(f) { f.request.body = 'x'; f.request.bodyBytes = [1, 2, 255] }")
        else { Issue.record("not modified"); return }
        #expect(m.body == Data([1, 2, 255]))
        guard case .modified(let sub) = run("function handle(f) { f.request.bodyBytes = f.request.bodyBytes.subarray(2, 4) }")
        else { Issue.record("not modified"); return }
        #expect(sub.body == Data("co".utf8))
    }

    @Test func binaryBodyIsNullText() {
        let bin = ScriptMessage(method: "POST", url: "https://a.test/", headers: [], body: Data([0xff, 0xfe, 0x00]))
        #expect(run("function handle(f) { if (f.request.body !== null) throw new Error('text') ; console.log(f.request.bodyBytes[0]) }",
                    request: bin) == .unchanged)
        #expect(logs.all.last?.message == "255")
    }

    @Test func mockAndAbort() {
        let code = "function handle(f) { f.response = { status: 418, headers: { 'X-Mock': 'yes' }, body: { tea: true } } }"
        #expect(run(code) == .respond(ScriptMessage(status: 418, headers: [HeaderField(name: "X-Mock", value: "yes")],
                                                     body: Data(#"{"tea":true}"#.utf8))))
        #expect(run("function handle(f) { f.abort() }") == .abort)
        #expect(run("function handle(f) { f.abort() }", phase: .response) == .abort)
    }

    @Test func changingTheURL() {
        guard case .modified(let m) = run("function handle(f) { f.request.url = f.request.url.replace('api.test', 'staging.test') }")
        else { Issue.record("not modified"); return }
        #expect(m.url == "https://staging.test/v1/items?q=1")
        #expect(run("function handle(f) { f.request.url = 'nope' }") == .failed("flow.request.url is not an http(s) URL: nope"))
    }

    @Test func sharedStateCrossesScripts() {
        let r = runner()
        #expect(run("function handle(f) { $shared.token = JSON.parse(f.response.body).items.length }", phase: .response, runner: r) == .unchanged)
        guard case .modified(let m) = run("function handle(f) { f.request.headers.Authorization = 'Bearer ' + $shared.token }", runner: r)
        else { Issue.record("not modified"); return }
        #expect(m.headers.value(for: "Authorization") == "Bearer 2")
        r.resetShared()
        #expect(run("function handle(f) { if ($shared.token !== undefined) throw new Error('kept') }", runner: r) == .unchanged)
    }

    @Test func library() {
        let code = """
        function handle(f) {
          console.log(btoa("hi"), atob("aGk="), base64.encode("xin chào"), utf8.decode(base64.decode("eGluIGNow6Bv")))
          console.log(crypto.md5("abc"), crypto.sha1("abc"))
          console.log(crypto.sha256("abc"))
          console.log(crypto.hmac("sha256", "key", "The quick brown fox jumps over the lazy dog"))
          console.log(crypto.sha512(new Uint8Array([])).slice(0, 16), base64.decode("_-8").length)
          console.log({a: 1}, [1, "x"], undefined, null, new Uint8Array(3))
        }
        """
        #expect(run(code) == .unchanged)
        #expect(logs.all.map(\.message) == [
            "aGk= hi eGluIGNow6Bv xin chào",
            "900150983cd24fb0d6963f7d28e17f72 a9993e364706816aba3e25717850c26c9cd0d89d",
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8",
            "cf83e1357eefb8bd 2",
            #"{"a":1} [1,"x"] undefined null Uint8Array(3)"#,
        ])
    }

    @Test func errors() {
        #expect(run("function handle(f) {") .failedMessage?.contains("SyntaxError") == true)
        #expect(run("var x = 1") == .failed("Error: The script has no handle(flow) function"))
        #expect(run("function handle(f) { null.x }").failedMessage?.contains("TypeError") == true)
        #expect(run("function handle(f) { f.request.body = 5 }") == .failed("TypeError: body must be a string, an object or null"))
        #expect(run("function handle(f) { f.response.status = 42 }", phase: .response) == .failed("Invalid status 42"))
        #expect(run("const handle = f => { throw new Error('boom') }") == .failed("Error: boom (line 1)"))
        #expect(logs.all.filter { $0.level == .error }.count == 6)
    }

    @Test func missingScript() {
        let r = runner()
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var outcome: ScriptOutcome?
        r.run(scriptID: UUID(), phase: .request, flowID: UUID(), request: request, response: nil) { outcome = $0; done.signal() }
        done.wait()
        #expect(outcome == .failed("Script file is missing"))
    }

    @Test func loadedScriptsRunAndReload() {
        let r = runner()
        let id = UUID()
        r.load([ScriptSource(id: id, name: "a", code: "function handle(f) { f.request.headers.V = '1' }")])
        func once() -> ScriptOutcome {
            let done = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var outcome: ScriptOutcome?
            r.run(scriptID: id, phase: .request, flowID: UUID(), request: request, response: nil) { outcome = $0; done.signal() }
            done.wait()
            return outcome!
        }
        guard case .modified(let a) = once() else { Issue.record("not modified"); return }
        #expect(a.headers.value(for: "V") == "1")
        r.load([ScriptSource(id: id, name: "a", code: "function handle(f) { f.request.headers.V = '2' }")])
        guard case .modified(let b) = once() else { Issue.record("not modified"); return }
        #expect(b.headers.value(for: "V") == "2")
    }

    @Test func infiniteLoopTimesOut() {
        let r = runner(timeout: 0.3)
        let started = Date()
        #expect(run("function handle(f) { while (true) {} }", runner: r) == .failed("Script timed out after 0.3 s"))
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(run("function handle(f) { f.request.headers.After = 'yes' }", runner: r) != .unchanged)
    }
}

extension ScriptOutcome {
    var failedMessage: String? { if case .failed(let m) = self { m } else { nil } }
}
