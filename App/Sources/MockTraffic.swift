#if DEBUG
import Foundation
import ProxyModel
import Storage

/// Sample traffic for the Simulator, where the tunnel can't run; written when the app launches with `-mockTraffic`.
enum MockTraffic {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-mockTraffic") }
    /// `-screenshots` shows the proxy as on and hides tips and the Simulator-only tunnel error, for App Store screenshots.
    static var isScreenshot: Bool { ProcessInfo.processInfo.arguments.contains("-screenshots") }
    /// `-mockOpen <host>` opens that host and its newest request at launch (in the timeline, just the request), for screenshots without tapping.
    static var openHost: String? { UserDefaults.standard.string(forKey: "mockOpen") }
    /// `-mockPath <text>` picks the request whose URL contains that text instead of the newest one.
    static var openPath: String? { UserDefaults.standard.string(forKey: "mockPath") }

    static func pick(_ flows: [FlowRecord], host: String? = nil) -> FlowRecord? {
        let candidates = host.map { h in flows.filter { $0.host == h } } ?? flows
        if let openPath { return candidates.first { $0.url?.contains(openPath) == true } }
        return candidates.first
    }

    private struct Sample {
        var host: String
        var method: String
        var path: String
        var status: Int?
        var kind: FlowKind = .https
        var state: FlowState = .completed
        var contentType = "application/json"
        var request: String?
        var response: String?
        var graphQL: String?
        var error: String?
        var ms: Double = 120
    }

    private static let samples: [Sample] = [
        Sample(host: "api.github.com", method: "GET", path: "/repos/apple/swift/pulls?state=open&per_page=30", status: 200,
               response: #"[{"number":78012,"title":"[Concurrency] Fix isolation of default arguments","user":{"login":"ktoso"},"draft":false,"labels":[{"name":"concurrency"}]},{"number":78007,"title":"Sema: diagnose unreachable catch","user":{"login":"xedin"},"draft":true,"labels":[]}]"#),
        Sample(host: "api.github.com", method: "GET", path: "/user", status: 401,
               response: #"{"message":"Bad credentials","documentation_url":"https://docs.github.com/rest"}"#),
        Sample(host: "httpbin.org", method: "POST", path: "/post", status: 200,
               request: #"{"name":"Passage","version":"0.1.0","tags":["proxy","ios"]}"#,
               response: #"{"args":{},"data":"{\"name\":\"Passage\"}","headers":{"Content-Type":"application/json","Host":"httpbin.org"},"json":{"name":"Passage","tags":["proxy","ios"],"version":"0.1.0"},"origin":"113.161.1.1","url":"https://httpbin.org/post"}"#, ms: 340),
        Sample(host: "httpbin.org", method: "GET", path: "/status/500", status: 500, contentType: "text/html",
               response: "<!doctype html><html><body><h1>Internal Server Error</h1></body></html>"),
        Sample(host: "httpbin.org", method: "DELETE", path: "/anything/42", status: 204, response: nil, ms: 90),
        Sample(host: "api.example-shop.com", method: "POST", path: "/graphql", status: 200,
               request: #"{"operationName":"GetCart","query":"query GetCart($id: ID!) { cart(id: $id) { id items { sku qty price } total } }","variables":{"id":"c_9f2"}}"#,
               response: #"{"data":{"cart":{"id":"c_9f2","items":[{"sku":"TSHIRT-M","qty":2,"price":19.5},{"sku":"MUG","qty":1,"price":12}],"total":51}}}"#,
               graphQL: "query GetCart", ms: 210),
        Sample(host: "api.example-shop.com", method: "POST", path: "/graphql", status: 200,
               request: #"{"operationName":"AddToCart","query":"mutation AddToCart($sku: String!) { addToCart(sku: $sku) { id } }","variables":{"sku":"MUG"}}"#,
               response: #"{"data":{"addToCart":{"id":"c_9f2"}}}"#, graphQL: "mutation AddToCart"),
        Sample(host: "api.example-shop.com", method: "PUT", path: "/v2/users/1842/preferences", status: 200,
               request: #"{"currency":"VND","language":"vi","notifications":{"email":false,"push":true}}"#,
               response: #"{"ok":true}"#),
        Sample(host: "cdn.example-shop.com", method: "GET", path: "/images/products/tshirt-m@3x.png", status: 200, contentType: "image/png", ms: 60),
        Sample(host: "cdn.example-shop.com", method: "GET", path: "/assets/app.4f2a9c.js", status: 304, contentType: "application/javascript", ms: 40),
        Sample(host: "fonts.gstatic.com", method: "GET", path: "/s/inter/v13/UcCO3FwrK3iLTeHuS_fvQtMwCp50KnMw2boKoduKmMEVuLyfAZ9hiA.woff2", status: 200, contentType: "font/woff2"),
        Sample(host: "graph.facebook.com", method: "POST", path: "/v19.0/app/activities", status: nil, state: .failed,
               error: "The upstream TLS handshake failed: certificate pinned by the app"),
        Sample(host: "firebaseinstallations.googleapis.com", method: "POST", path: "/v1/projects/passage-demo/installations", status: 200,
               request: #"{"fid":"cK9mZ3x2Q0e","appId":"1:1234:ios:abcd","authVersion":"FIS_v2","sdkVersion":"i:11.4.0"}"#,
               response: #"{"name":"projects/1234/installations/cK9mZ3x2Q0e","refreshToken":"3_AS3qfwI…","authToken":{"token":"eyJhbGciOiJFUzI1NiJ9.eyJhcHBJZCI6IjE6MTIzNCJ9.sig","expiresIn":"604800s"}}"#),
        Sample(host: "example.com", method: "GET", path: "/", status: 200, kind: .http, contentType: "text/html",
               response: "<!doctype html><html><head><title>Example Domain</title></head><body><h1>Example Domain</h1><p>This domain is for use in illustrative examples.</p></body></html>"),
        Sample(host: "api.weather.example", method: "GET", path: "/v1/forecast?lat=21.03&lon=105.85&hourly=temperature_2m", status: 200,
               response: #"{"latitude":21.03,"longitude":105.85,"hourly":{"time":["2026-10-22T00:00","2026-10-22T01:00"],"temperature_2m":[24.1,23.8]}}"#, ms: 820),
        Sample(host: "api.example-shop.com", method: "GET", path: "/v2/orders?page=1", status: nil, state: .active, response: nil),
        Sample(host: "slow.example.net", method: "GET", path: "/timeout", status: nil, state: .failed, error: "The upstream connection timed out after 30 s", ms: 30000),
        Sample(host: "gateway.icloud.com", method: "POST", path: "/ckdatabase/api/client/record/sync", status: 200),
        Sample(host: "push.apple.com", method: "CONNECT", path: "", status: nil, kind: .raw),
    ]

    /// Writes the samples with fixed IDs, so a second launch updates them instead of adding copies.
    /// A few rules of different tools, so the Rules tab has something to show in screenshots.
    static func seedRules(_ store: FlowStore) {
        guard (try? store.rules().isEmpty) == true else { return }
        try? FileManager.default.createDirectory(at: store.rulesDirectory, withIntermediateDirectories: true)
        let mock = Rule(tool: .mapLocal, name: "Mock cart", match: URLMatch(pattern: "https://api.example-shop.com/graphql", method: "POST"),
                        action: .mapLocal(status: 200, headers: [HeaderField(name: "Content-Type", value: "application/json")]))
        try? Data(#"{"data":{"cart":{"id":"c_9f2","items":[],"total":0}}}"#.utf8).write(to: store.ruleBodyURL(mock.id))
        let rules = [
            Rule(tool: .breakpoint, name: "Pause checkout", match: URLMatch(pattern: "https://api.example-shop.com/checkout*"),
                 action: .breakpoint(request: true, response: true)),
            mock,
            Rule(tool: .mapRemote, name: "Use staging API", match: URLMatch(pattern: "https://api.example-shop.com/*"),
                 action: .mapRemote(target: "https://staging.example-shop.com")),
            Rule(tool: .blockList, name: "Block analytics", match: URLMatch(pattern: "https://graph.facebook.com/*"), action: .block),
            Rule(tool: .dnsSpoof, name: "Local server", match: URLMatch(pattern: "dev.example-shop.com"), action: .dnsSpoof(addresses: ["192.168.1.20"])),
            Rule(tool: .noCaching, enabled: false, name: "No caching for images", match: URLMatch(pattern: "https://cdn.example-shop.com/*"), action: .noCaching),
        ]
        let script = Rule(tool: .script, name: "Flag new users", match: URLMatch(pattern: "https://api.example-shop.com/v2/users/*"),
                          action: .script(request: false, response: true))
        try? Data("""
            function handle(flow) {
              const user = JSON.parse(flow.response.body);
              user.flags = { newCheckout: true, betaBanner: true };
              user.plan = "premium";
              flow.response.body = user; // objects are sent as JSON
              console.log("Patched user", user.id);
            }

            """.utf8).write(to: store.ruleScriptURL(script.id))
        for rule in rules + [script] { try? store.saveRule(rule) }
    }

    static func seed(_ store: FlowStore) {
        let now = Date()
        var flows: [FlowRecord] = []
        for (index, s) in samples.enumerated() {
            let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 1))!
            let start = now.addingTimeInterval(-Double(samples.count - index) * 37)
            var f = FlowRecord(id: id, startedAt: start, kind: s.kind, host: s.host, ip: "93.184.216.\(index + 10)", port: s.kind == .http ? 80 : 443)
            f.state = s.state
            f.httpVersion = s.kind == .raw ? nil : (index.isMultiple(of: 3) ? "HTTP/1.1" : "HTTP/2")
            if s.kind != .raw {
                f.method = s.method
                f.url = "\(s.kind == .http ? "http" : "https")://\(s.host)\(s.path)"
            }
            f.statusCode = s.status
            f.error = s.error
            f.graphQL = s.graphQL
            f.connectMs = s.ms * 0.3
            f.ttfbMs = s.state == .active ? nil : s.ms * 0.8
            f.endedAt = s.state == .active ? nil : start.addingTimeInterval(s.ms / 1000)
            f.requestHeaders = [
                HeaderField(name: "Host", value: s.host),
                HeaderField(name: "User-Agent", value: "ExampleShop/5.2 (iPhone; iOS 26.0; Scale/3.00)"),
                HeaderField(name: "Accept", value: "*/*"),
                HeaderField(name: "Authorization", value: "Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxODQyIn0.4pZ"),
            ] + (s.request == nil ? [] : [HeaderField(name: "Content-Type", value: "application/json")])
            if s.status != nil {
                f.responseHeaders = [
                    HeaderField(name: "Content-Type", value: s.contentType),
                    HeaderField(name: "Cache-Control", value: "no-cache"),
                    HeaderField(name: "Date", value: "Thu, 22 Oct 2026 09:00:00 GMT"),
                    HeaderField(name: "Set-Cookie", value: "session=abc123; Path=/; HttpOnly; Secure"),
                ]
            }
            if let body = s.request {
                try? store.bodies.write(Data(body.utf8), flowID: id, side: .request)
                f.requestBytes = body.utf8.count
            }
            if let body = s.response {
                try? store.bodies.write(Data(body.utf8), flowID: id, side: .response)
                f.responseBytes = body.utf8.count
            } else if s.status == 200 {
                f.responseBytes = 48_213
            }
            flows.append(f)
        }

        // One WebSocket conversation.
        let wsID = UUID(uuidString: "00000000-0000-4000-8000-000000000999")!
        var ws = FlowRecord(id: wsID, startedAt: now.addingTimeInterval(-15), kind: .https, host: "realtime.example-shop.com", ip: "93.184.216.99", port: 443)
        ws.state = .active
        ws.method = "GET"
        ws.url = "wss://realtime.example-shop.com/socket?v=2"
        ws.statusCode = 101
        ws.httpVersion = "HTTP/1.1"
        ws.requestHeaders = [HeaderField(name: "Upgrade", value: "websocket"), HeaderField(name: "Connection", value: "Upgrade")]
        ws.responseHeaders = [HeaderField(name: "Upgrade", value: "websocket")]
        flows.append(ws)
        let texts: [(WebSocketDirection, String)] = [
            (.sent, #"{"type":"subscribe","channel":"cart:c_9f2"}"#),
            (.received, #"{"type":"ack","channel":"cart:c_9f2"}"#),
            (.received, #"{"type":"cart.updated","total":51,"items":2}"#),
            (.sent, #"{"type":"ping"}"#),
        ]
        let messages = texts.enumerated().map { i, m in
            WebSocketMessage(flowID: wsID, seq: i, at: ws.startedAt.addingTimeInterval(Double(i)), direction: m.0, opcode: .text,
                             length: m.1.utf8.count, payload: Data(m.1.utf8), truncated: false)
        }
        try? store.upsert(flows, messages: messages)
    }
}
#endif
