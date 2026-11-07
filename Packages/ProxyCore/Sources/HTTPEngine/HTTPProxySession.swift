import Foundation
import NIOCore
import NIOHTTP1
import NIOHTTP2
import ProxyModel
import Rules

/// Terminates HTTP/1.1 from the client and replays each exchange upstream,
/// recording heads, bodies and timing. One instance per client connection.
///
/// Pipeline (downstream): [TLS server?] → HTTPResponseEncoder → HTTPRequestDecoder → self,
///   or on an HTTP/2 stream: HTTP2FramePayloadToHTTP1ServerCodec → self.
/// Pipeline (upstream):   [TLS client?] → HTTPRequestEncoder → HTTPResponseDecoder → UpstreamHandler,
///   or on an HTTP/2 stream: HTTP2FramePayloadToHTTP1ClientCodec → UpstreamHandler.
final class HTTPProxySession: ChannelDuplexHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundIn = HTTPServerResponsePart
    typealias OutboundOut = HTTPServerResponsePart

    /// Opens a new upstream connection with transport (and TLS) ready, but no HTTP handlers.
    typealias Dialer = @Sendable (EventLoop) -> EventLoopFuture<Channel>

    /// How the client side is framed: a whole HTTP/1.1 connection, or one HTTP/2 stream.
    enum Framing { case http1, h2Stream }

    /// Confined to the session's event loop.
    private final class Exchange: @unchecked Sendable {
        var record: FlowRecord
        let started = Date()
        var requestBody: BodySink?
        var responseBody: BodySink?
        var respondedLocally = false
        /// Close the client connection once this response is written (Connection: close on either side).
        var closeAfter = false
        /// Set by a 101 response; the splice happens on its `.end`, after the decoder is done with HTTP.
        var upgradeProtocol: String?
        /// The response head arrived from upstream.
        var responseHeadSent = false
        /// The response head was written to the client.
        var clientGotHead = false
        /// The whole response arrived from upstream (it may still be held for a script or breakpoint).
        var responseEnded = false
        /// Where this request goes; nil means the connection's original destination.
        var target: UpstreamTarget?
        var noCaching = false
        var breakpoint: (request: Bool, response: Bool, name: String)?
        /// The Scripting rule for this request and the phases it still has to run.
        var script: (id: UUID, name: String, request: Bool, response: Bool)?
        /// The request body as sent upstream, kept for a response-phase script; nil when no script needs it.
        var sentRequestBody: Data?
        /// A request held for a breakpoint: its head and the body so far.
        var heldRequest: (head: HTTPRequestHead, body: ByteBuffer)?
        /// A response held for a breakpoint.
        var heldResponse: (head: HTTPResponseHead, body: ByteBuffer)?
        /// The breakpoint item while this exchange is paused.
        var pausedItem: UUID?
        /// The start of a request body that may be GraphQL, kept until the request ends.
        var graphQLBody: Data?
        init(record: FlowRecord) { self.record = record }

        func addNote(_ note: String) {
            record.note = record.note.map { "\($0) · \(note)" } ?? note
        }
    }

    private let config: EngineConfig
    private let destination: IPEndpoint
    private let scheme: String
    private let defaultHost: String
    private let dial: Dialer
    private let framing: Framing
    /// The HTTP/1.1 codecs, removed on a 101 upgrade; nil on an HTTP/2 stream.
    private let encoder: HTTPResponseEncoder?
    private let decoder: ByteToMessageHandler<HTTPRequestDecoder>?
    /// Added to every flow of this connection (e.g. "Throttled: 3G").
    private let connectionNote: String?
    /// Where the current upstream connection goes; nil is the original destination.
    private var upstreamTarget: UpstreamTarget?

    private var context: ChannelHandlerContext?
    private var upstream: Channel?
    private var upstreamHandler: UpstreamHandler?
    /// The current upstream is an HTTP/2 stream (otherwise an HTTP/1.1 connection).
    private var upstreamIsH2 = false
    private var connecting = false
    private var pending: [HTTPClientRequestPart] = []
    private var exchanges: [Exchange] = []
    private var pendingRead = false
    /// The client sent FIN on an HTTP/1 connection: close once the last response is out.
    private var clientHalfClosed = false
    private var lastResponseWrite: EventLoopFuture<Void>?

    init(config: EngineConfig, destination: IPEndpoint, scheme: String, defaultHost: String, framing: Framing,
         encoder: HTTPResponseEncoder?, decoder: ByteToMessageHandler<HTTPRequestDecoder>?,
         preconnected: Channel?, dial: @escaping Dialer, connectionNote: String? = nil) {
        self.config = config
        self.framing = framing
        self.connectionNote = connectionNote
        self.destination = destination
        self.scheme = scheme
        self.defaultHost = defaultHost
        self.encoder = encoder
        self.decoder = decoder
        self.dial = dial
        self.upstream = preconnected
    }

    /// Adds encoder, decoder and session to `channel` (after any TLS handler already there).
    /// On an HTTP/2 stream the stream's HTTP/1 codec must already be in place and only the session is added.
    static func install(on channel: Channel, config: EngineConfig, destination: IPEndpoint, scheme: String,
                        defaultHost: String, framing: Framing = .http1, preconnected: Channel?, dial: @escaping Dialer,
                        connectionNote: String? = nil) throws {
        let encoder = framing == .http1 ? HTTPResponseEncoder() : nil
        let decoder = framing == .http1 ? ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)) : nil
        let session = HTTPProxySession(config: config, destination: destination, scheme: scheme,
                                       defaultHost: defaultHost, framing: framing, encoder: encoder, decoder: decoder,
                                       preconnected: preconnected, dial: dial, connectionNote: connectionNote)
        if let encoder, let decoder { try channel.pipeline.syncOperations.addHandlers([encoder, decoder]) }
        try channel.pipeline.syncOperations.addHandler(session)
        if let preconnected { try session.adopt(preconnected) }
    }

    func handlerAdded(context: ChannelHandlerContext) { self.context = context }
    func handlerRemoved(context: ChannelHandlerContext) { self.context = nil }

    // MARK: Client → upstream

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): startExchange(head)
        case .body(var buffer):
            guard let ex = exchanges.last, !ex.respondedLocally else { return }
            ex.record.requestBytes += buffer.readableBytes
            if let body = ex.graphQLBody, body.count <= GraphQLOperation.maxBodyBytes {
                ex.graphQLBody = body + buffer.readableBytesView.prefix(GraphQLOperation.maxBodyBytes + 1 - body.count)
            }
            if let body = ex.sentRequestBody {
                ex.sentRequestBody = body.count + buffer.readableBytes <= BreakpointCenter.maxBodyBytes
                    ? body + buffer.readableBytesView : Data()
            }
            if var held = ex.heldRequest {
                held.body.writeBuffer(&buffer)
                ex.heldRequest = held
                if held.body.readableBytes > BreakpointCenter.maxBodyBytes {
                    let scripted = ex.script?.request == true
                    ex.script?.request = false
                    releaseHeldRequest(ex, note: scripted ? "Script skipped: body over 10 MB" : "Breakpoint skipped: body over 10 MB")
                }
                return
            }
            ex.requestBody?.append(Array(buffer.readableBytesView))
            send(.body(.byteBuffer(buffer)))
        case .end(let trailers):
            guard let ex = exchanges.last else { return }
            if let body = ex.graphQLBody {
                ex.graphQLBody = nil
                detectGraphQL(ex, body: body)
            }
            if ex.heldRequest != nil, !ex.respondedLocally {
                if ex.script?.request == true { runRequestScript(ex) } else { pauseRequest(ex) }
                return
            }
            ex.requestBody?.finish()
            if !ex.respondedLocally { send(.end(trailers)) }
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) { upstream?.flush() }

    private func startExchange(_ head: HTTPRequestHead) {
        let hostHeader = head.headers.first(name: "host")
        let host = hostHeader.map(Self.stripPort) ?? defaultHost
        var record = FlowRecord(kind: scheme == "https" ? .https : .http, host: host,
                                ip: destination.host, port: Int(destination.port))
        record.method = head.method.rawValue
        record.url = "\(scheme)://\(hostHeader ?? defaultHost)\(head.uri)"
        record.requestHeaders = head.headers.map { HeaderField(name: $0.name, value: $0.value) }
        record.httpVersion = framing == .h2Stream ? "HTTP/2" : "HTTP/1.1"
        let ex = Exchange(record: record)
        if let connectionNote { ex.addNote(connectionNote) }
        ex.closeAfter = framing == .http1 && !head.isKeepAlive
        exchanges.append(ex)
        if let connection { config.reaper?.begin(connection) }
        if config.recordBodies() {
            ex.requestBody = config.sink.bodySink(flowID: record.id, side: .request)
        }
        let contentType = head.headers.first(name: "content-type")
        if GraphQLOperation.mightBeGraphQL(method: head.method.rawValue, url: record.url ?? "", contentType: contentType) {
            ex.graphQLBody = Data()
        }
        config.sink.record(ex.record)

        var outHead = head
        if let engine = config.rules, applyRules(engine, to: ex, head: &outHead) { return }
        for hook in config.hooks {
            switch hook.decide(flow: ex.record, head: Self.snapshot(head)) {
            case .forward(let snap):
                outHead = Self.apply(snap, to: outHead)
            case .respond(let status, let headers, let body):
                respondLocally(ex, status: status, headers: headers, body: body)
                return
            }
        }
        if ex.breakpoint?.request == true || ex.script?.request == true {
            ex.heldRequest = (outHead, context?.channel.allocator.buffer(capacity: 0) ?? ByteBuffer())
            return
        }
        sendHead(outHead, for: ex)
    }

    private func detectGraphQL(_ ex: Exchange, body: Data) {
        guard let op = GraphQLOperation.detect(method: ex.record.method ?? "", url: ex.record.url ?? "",
                                               contentType: ex.record.requestHeaders.value(for: "Content-Type"), body: body)
        else { return }
        ex.record.graphQL = op
        config.sink.record(ex.record)
    }

    // MARK: Rules

    /// Applies Block, Map Local, Map Remote, No Caching and notes Breakpoint for one request.
    /// - Returns: true when the exchange was answered or ended here.
    private func applyRules(_ engine: RuleEngine, to ex: Exchange, head: inout HTTPRequestHead) -> Bool {
        let rules = engine.current
        guard let url = ex.record.url else { return false }
        let method = head.method.rawValue
        if let rule = rules.first(.blockList, url: url, method: method) {
            ex.respondedLocally = true
            ex.addNote("Blocked by rule \"\(rule.name)\"")
            finish(ex, state: .failed, error: "Blocked by rule")
            context?.close(promise: nil)
            return true
        }
        if let rule = rules.first(.mapLocal, url: url, method: method), case .mapLocal(let status, let headers) = rule.action {
            ex.addNote("Map Local: \(rule.name)")
            if let body = engine.mapLocalBody(rule.id) {
                respondLocally(ex, status: status, headers: Self.withoutFraming(headers), body: [UInt8](body))
            } else {
                respondLocally(ex, status: 500, headers: [HeaderField(name: "Content-Type", value: "text/plain; charset=utf-8")],
                               body: Array("Passage: Map Local file is missing\n".utf8))
            }
            return true
        }
        if let rule = rules.first(.mapRemote, url: url, method: method), case .mapRemote(let target) = rule.action,
           let mapped = RuleSet.mapRemote(url, to: target), let t = UpstreamTarget(url: mapped) {
            ex.target = t
            head.uri = t.requestTarget
            head.headers.replaceOrAdd(name: "host", value: t.hostHeader)
            ex.addNote("Mapped to \(mapped)")
        }
        if rules.first(.noCaching, url: url, method: method) != nil {
            ex.noCaching = true
            head.headers.remove(name: "if-none-match")
            head.headers.remove(name: "if-modified-since")
            head.headers.replaceOrAdd(name: "cache-control", value: "no-cache")
            head.headers.replaceOrAdd(name: "pragma", value: "no-cache")
        }
        if let rule = rules.first(.script, url: url, method: method), case .script(let request, let response) = rule.action,
           engine.scripts != nil, request || response {
            if config.recordBodies() {
                ex.script = (rule.id, rule.name, request, response)
                if response { ex.sentRequestBody = Data() }
            } else {
                ex.addNote("Script skipped: low memory")
            }
        }
        if let rule = rules.first(.breakpoint, url: url, method: method), case .breakpoint(let request, let response) = rule.action {
            ex.breakpoint = (request, response, rule.name)
        }
        return false
    }

    // MARK: Scripts

    private func scriptNote(_ ex: Exchange, _ name: String, _ detail: String? = nil) {
        let note = detail.map { "Script \"\(name)\": \($0)" } ?? "Script \"\(name)\""
        if ex.record.note?.contains(note) != true { ex.addNote(note) }
    }

    private func runRequestScript(_ ex: Exchange) {
        guard let held = ex.heldRequest, let script = ex.script, let host = config.rules?.scripts,
              let loop = context?.eventLoop else { return }
        ex.script?.request = false
        let message = ScriptMessage(method: held.head.method.rawValue, url: ex.record.url ?? "",
                                    headers: Self.fields(held.head.headers), body: Data(held.body.readableBytesView))
        host.run(scriptID: script.id, phase: .request, flowID: ex.record.id, request: message, response: nil) { [weak self] outcome in
            loop.execute { self?.requestScriptFinished(ex, outcome: outcome, name: script.name) }
        }
    }

    private func requestScriptFinished(_ ex: Exchange, outcome: ScriptOutcome, name: String) {
        guard var held = ex.heldRequest, exchanges.contains(where: { $0 === ex }) else { return }
        switch outcome {
        case .abort:
            ex.heldRequest = nil
            ex.respondedLocally = true
            ex.addNote("Aborted by script \"\(name)\"")
            finish(ex, state: .failed, error: "Aborted by script")
            context?.close(promise: nil)
            return
        case .respond(let m):
            ex.heldRequest = nil
            ex.addNote("Mocked by script \"\(name)\"")
            ex.requestBody?.append(Array(held.body.readableBytesView))
            respondLocally(ex, status: m.status ?? 200, headers: Self.withoutFraming(m.headers), body: [UInt8](m.body))
            return
        case .modified(let m):
            held.head = apply(m, to: ex, head: held.head)
            held.body = ByteBuffer(bytes: m.body)
            ex.heldRequest = held
            if ex.sentRequestBody != nil { ex.sentRequestBody = m.body }
            scriptNote(ex, name, "edited request")
        case .failed(let message):
            ex.addNote("Script error: \(message)")
        case .unchanged:
            scriptNote(ex, name)
        }
        config.sink.record(ex.record)
        if ex.breakpoint?.request == true {
            pauseRequest(ex)
            return
        }
        ex.heldRequest = nil
        ex.requestBody?.append(Array(held.body.readableBytesView))
        sendHead(held.head, for: ex)
        if held.body.readableBytes > 0 { send(.body(.byteBuffer(held.body))) }
        ex.requestBody?.finish()
        send(.end(nil))
    }

    /// The head for a request a script edited; a URL on another host or port sends it there.
    private func apply(_ m: ScriptMessage, to ex: Exchange, head original: HTTPRequestHead) -> HTTPRequestHead {
        var head = original
        head.method = HTTPMethod(rawValue: m.method)
        var headers = HTTPHeaders(Self.withoutFraming(m.headers).map { ($0.name, $0.value) })
        let framed = original.headers.contains(name: "content-length") || original.headers.contains(name: "transfer-encoding")
        if !m.body.isEmpty || framed { headers.add(name: "Content-Length", value: "\(m.body.count)") }
        if m.url != ex.record.url, let t = UpstreamTarget(url: m.url) {
            let sameEndpoint = UpstreamTarget(url: ex.record.url ?? "")?.endpoint == t.endpoint
            if !sameEndpoint { ex.target = t }
            head.uri = t.requestTarget
            headers.replaceOrAdd(name: "host", value: t.hostHeader)
            ex.record.url = m.url
        }
        head.headers = headers
        ex.record.method = m.method
        ex.record.requestHeaders = Self.fields(headers)
        ex.record.requestBytes = m.body.count
        return head
    }

    private func runResponseScript(_ ex: Exchange) {
        guard let held = ex.heldResponse, let script = ex.script, let host = config.rules?.scripts,
              let loop = context?.eventLoop else { return }
        ex.script?.response = false
        let request = ScriptMessage(method: ex.record.method ?? "", url: ex.record.url ?? "", headers: ex.record.requestHeaders,
                                    body: ex.sentRequestBody ?? Data())
        let response = ScriptMessage(method: request.method, url: request.url, status: Int(held.head.status.code),
                                     headers: Self.fields(held.head.headers), body: Data(held.body.readableBytesView))
        host.run(scriptID: script.id, phase: .response, flowID: ex.record.id, request: request, response: response) { [weak self] outcome in
            loop.execute { self?.responseScriptFinished(ex, outcome: outcome, name: script.name) }
        }
    }

    private func responseScriptFinished(_ ex: Exchange, outcome: ScriptOutcome, name: String) {
        guard let context, var held = ex.heldResponse, exchanges.contains(where: { $0 === ex }) else { return }
        switch outcome {
        case .abort:
            ex.heldResponse = nil
            ex.addNote("Aborted by script \"\(name)\"")
            finish(ex, state: .failed, error: "Aborted by script")
            context.close(promise: nil)
            return
        case .modified(let m), .respond(let m):
            var headers = HTTPHeaders(Self.withoutFraming(m.headers).map { ($0.name, $0.value) })
            headers.add(name: "Content-Length", value: "\(m.body.count)")
            let status = HTTPResponseStatus(statusCode: m.status ?? Int(held.head.status.code))
            held.head = HTTPResponseHead(version: held.head.version, status: status, headers: headers)
            held.body = ByteBuffer(bytes: m.body)
            ex.heldResponse = held
            ex.record.statusCode = Int(status.code)
            ex.record.responseHeaders = Self.fields(headers)
            ex.record.responseBytes = m.body.count
            scriptNote(ex, name, "edited response")
        case .failed(let message):
            ex.addNote("Script error: \(message)")
        case .unchanged:
            scriptNote(ex, name)
        }
        config.sink.record(ex.record)
        if ex.breakpoint?.response == true {
            pauseResponse(ex)
            return
        }
        ex.heldResponse = nil
        ex.responseBody?.append(Array(held.body.readableBytesView))
        context.write(wrapOutboundOut(.head(held.head)), promise: nil)
        ex.clientGotHead = true
        if held.body.readableBytes > 0 { context.write(wrapOutboundOut(.body(.byteBuffer(held.body))), promise: nil) }
        completeResponse(ex, trailers: nil)
    }

    static func fields(_ headers: HTTPHeaders) -> [HeaderField] {
        headers.map { HeaderField(name: $0.name, value: $0.value) }
    }

    static func withoutFraming(_ headers: [HeaderField]) -> [HeaderField] {
        headers.filter { !["content-length", "transfer-encoding"].contains($0.name.lowercased()) }
    }

    /// Sends a request head on the upstream for the exchange's target, switching upstream when the target differs.
    private func sendHead(_ head: HTTPRequestHead, for ex: Exchange) {
        if ex.target?.endpoint != upstreamTarget?.endpoint {
            if let upstream {
                upstreamHandler?.detach()
                upstream.close(promise: nil)
            }
            upstream = nil
            upstreamHandler = nil
            upstreamTarget = ex.target
        }
        send(.head(head))
    }

    /// Sends a held request on unchanged (breakpoint skipped) and streams the rest.
    private func releaseHeldRequest(_ ex: Exchange, note: String) {
        guard let held = ex.heldRequest else { return }
        ex.heldRequest = nil
        ex.addNote(note)
        ex.requestBody?.append(Array(held.body.readableBytesView))
        sendHead(held.head, for: ex)
        if held.body.readableBytes > 0 { send(.body(.byteBuffer(held.body))) }
    }

    private func pauseRequest(_ ex: Exchange) {
        guard let held = ex.heldRequest, let center = config.rules?.breakpoints, let loop = context?.eventLoop else { return }
        let item = BreakpointItem(flowID: ex.record.id, phase: .request, ruleName: ex.breakpoint?.name ?? "",
                                  method: held.head.method.rawValue, url: ex.record.url ?? "",
                                  headers: held.head.headers.map { HeaderField(name: $0.name, value: $0.value) })
        ex.record.state = .paused
        ex.pausedItem = item.id
        config.sink.record(ex.record)
        let accepted = center.pause(item, body: Data(held.body.readableBytesView)) { [weak self] decision in
            loop.execute { self?.resumeRequest(ex, item: item, decision: decision) }
        }
        if !accepted {
            ex.record.state = .active
            releaseHeldRequest(ex, note: "Breakpoint skipped: too many requests already paused")
            ex.requestBody?.finish()
            send(.end(nil))
        }
    }

    private func resumeRequest(_ ex: Exchange, item: BreakpointItem, decision: BreakpointDecision?) {
        guard let held = ex.heldRequest, exchanges.contains(where: { $0 === ex }) else { return }
        ex.heldRequest = nil
        ex.pausedItem = nil
        ex.record.state = .active
        let edited = config.rules?.breakpoints.takeBody(item.id) ?? Data()
        switch decision {
        case .abort?:
            ex.respondedLocally = true
            ex.addNote("Aborted at breakpoint")
            finish(ex, state: .failed, error: "Aborted at breakpoint")
            context?.close(promise: nil)
            return
        case nil:
            ex.addNote("Breakpoint timed out")
            ex.requestBody?.append(Array(held.body.readableBytesView))
            sendHead(held.head, for: ex)
            if held.body.readableBytes > 0 { send(.body(.byteBuffer(held.body))) }
        case .execute(let edit)?:
            var head = held.head
            head.method = HTTPMethod(rawValue: edit.method.uppercased())
            var headers = HTTPHeaders(Self.withoutFraming(edit.headers).map { ($0.name, $0.value) })
            if !edited.isEmpty || ["POST", "PUT", "PATCH"].contains(edit.method.uppercased()) {
                headers.add(name: "Content-Length", value: "\(edited.count)")
            }
            if edit.url != ex.record.url, let t = UpstreamTarget(url: edit.url) {
                let sameEndpoint = UpstreamTarget(url: ex.record.url ?? "")?.endpoint == t.endpoint
                if !sameEndpoint { ex.target = t }
                head.uri = t.requestTarget
                headers.replaceOrAdd(name: "host", value: t.hostHeader)
                ex.record.url = edit.url
            }
            head.headers = headers
            ex.record.method = edit.method.uppercased()
            ex.record.requestHeaders = headers.map { HeaderField(name: $0.name, value: $0.value) }
            ex.record.requestBytes = edited.count
            ex.addNote("Edited at breakpoint")
            ex.requestBody?.append([UInt8](edited))
            sendHead(head, for: ex)
            if !edited.isEmpty { send(.body(.byteBuffer(ByteBuffer(bytes: edited)))) }
        }
        ex.requestBody?.finish()
        config.sink.record(ex.record)
        send(.end(nil))
    }

    private func respondLocally(_ ex: Exchange, status: Int, headers: [HeaderField], body: [UInt8]) {
        guard let context else { return }
        ex.respondedLocally = true
        var h = HTTPHeaders(headers.map { ($0.name, $0.value) })
        if !h.contains(name: "content-length") { h.add(name: "content-length", value: "\(body.count)") }
        let head = HTTPResponseHead(version: .http1_1, status: .init(statusCode: status), headers: h)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(context.channel.allocator.buffer(bytes: body)))), promise: nil)
        lastResponseWrite = context.writeAndFlush(wrapOutboundOut(.end(nil)))
        ex.record.statusCode = status
        ex.record.responseHeaders = headers
        ex.record.responseBytes = body.count
        if let sink = config.recordBodies() ? config.sink.bodySink(flowID: ex.record.id, side: .response) : nil {
            sink.append(body)
            sink.finish()
        }
        finish(ex, state: .completed, error: nil)
    }

    private func send(_ part: HTTPClientRequestPart) {
        if let upstream, upstream.isActive, upstreamHandler != nil {
            upstream.write(forUpstream(part), promise: nil)
            return
        }
        pending.append(part)
        connectUpstreamIfNeeded()
    }

    /// A DNS Spoofing answer for a host this session dials by name, so redirected requests honor it like the app's own lookups.
    private func spoofedAddress(for host: String) -> String? {
        guard let rule = config.rules?.current.hostRule(.dnsSpoof, host: host, scheme: "dns"),
              case .dnsSpoof(let addresses) = rule.action else { return nil }
        let address = addresses.first { $0.contains(".") } ?? addresses.first
        if let address, let ex = exchanges.last { ex.addNote("Spoofed by \"\(rule.name)\": \(host) → \(address)") }
        return address
    }

    private func connectUpstreamIfNeeded() {
        guard !connecting, let context else { return }
        connecting = true
        let loop = context.eventLoop
        let opened = upstreamTarget.map { target in
            UpstreamDialer.dial(target, tls: config.upstreamTLS, on: loop, address: spoofedAddress(for: target.host))
        } ?? dial(loop)
        opened.whenComplete { [self] result in
            connecting = false
            defer { if pendingRead { pendingRead = false; self.context?.read() } }
            switch result {
            case .success(let ch):
                do {
                    try adopt(ch)
                    if !upstreamIsH2, let ex = exchanges.last, ex.record.connectMs == nil {
                        ex.record.connectMs = Date().timeIntervalSince(ex.started) * 1000
                    }
                    let parts = pending
                    pending.removeAll()
                    for p in parts { ch.write(forUpstream(p), promise: nil) }
                    ch.flush()
                } catch {
                    failAll(error: "Upstream setup failed: \(error)")
                }
            case .failure(let error):
                pending.removeAll()
                failAll(error: "Connect failed: \(error)")
            }
        }
    }

    /// Adds the upstream handlers; a stream from `H2Upstream` already carries its HTTP/1 codec.
    private func adopt(_ ch: Channel) throws {
        let handler = UpstreamHandler(session: self)
        let ops = ch.pipeline.syncOperations
        upstreamIsH2 = (try? ops.handler(type: HTTP2FramePayloadToHTTP1ClientCodec.self)) != nil
        if upstreamIsH2 {
            try ops.addHandler(handler)
        } else {
            let requestEncoder = HTTPRequestEncoder()
            let responseDecoder = ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes))
            try ops.addHandlers([requestEncoder, responseDecoder, handler])
            handler.removable = (requestEncoder, responseDecoder)
        }
        upstream = ch
        upstreamHandler = handler
    }

    /// A request from an HTTP/2 client sent to an HTTP/1.1 upstream (Map Remote) must say HTTP/1.1.
    private func forUpstream(_ part: HTTPClientRequestPart) -> HTTPClientRequestPart {
        guard !upstreamIsH2, case .head(var head) = part, head.version.major == 2 else { return part }
        head.version = .http1_1
        return .head(head)
    }

    // MARK: Upstream → client (called by UpstreamHandler on the same event loop)

    fileprivate func upstreamResponseHead(_ head: HTTPResponseHead) {
        guard let context, let ex = exchanges.first(where: { !$0.respondedLocally && !$0.responseHeadSent && $0.record.state == .active }) else { return }
        if head.status.code >= 100 && head.status.code < 200 && head.status != .switchingProtocols {
            // 100-continue and friends: pass through, the real head follows.
            context.writeAndFlush(wrapOutboundOut(.head(head)), promise: nil)
            return
        }
        ex.responseHeadSent = true
        if framing == .http1 && !head.isKeepAlive { ex.closeAfter = true }
        var head = head
        if ex.noCaching && head.status != .switchingProtocols {
            for name in ["etag", "last-modified", "expires"] { head.headers.remove(name: name) }
            head.headers.replaceOrAdd(name: "cache-control", value: "no-store")
        }
        ex.record.statusCode = Int(head.status.code)
        ex.record.responseHeaders = head.headers.map { HeaderField(name: $0.name, value: $0.value) }
        ex.record.ttfbMs = Date().timeIntervalSince(ex.started) * 1000
        if config.recordBodies() {
            ex.responseBody = config.sink.bodySink(flowID: ex.record.id, side: .response)
        }
        if head.status == .switchingProtocols {
            context.writeAndFlush(wrapOutboundOut(.head(head)), promise: nil)
            ex.upgradeProtocol = head.headers.first(name: "upgrade") ?? "unknown"
            return
        }
        config.sink.record(ex.record)
        if ex.breakpoint?.response == true || ex.script?.response == true {
            ex.heldResponse = (head, context.channel.allocator.buffer(capacity: 0))
            return
        }
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        ex.clientGotHead = true
    }

    fileprivate func upstreamResponseBody(_ buffer: ByteBuffer) {
        guard let context, let ex = exchanges.first(where: { $0.responseHeadSent && !$0.responseEnded && $0.record.state == .active }) else { return }
        ex.record.responseBytes += buffer.readableBytes
        if var held = ex.heldResponse {
            var buffer = buffer
            held.body.writeBuffer(&buffer)
            ex.heldResponse = held
            if held.body.readableBytes > BreakpointCenter.maxBodyBytes {
                let scripted = ex.script?.response == true
                ex.script?.response = false
                releaseHeldResponse(ex, note: scripted ? "Script skipped: body over 10 MB" : "Breakpoint skipped: body over 10 MB")
            }
            return
        }
        ex.responseBody?.append(Array(buffer.readableBytesView))
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
    }

    fileprivate func upstreamResponseEnd(_ trailers: HTTPHeaders?) {
        guard let ex = exchanges.first(where: { $0.responseHeadSent && !$0.responseEnded && $0.record.state == .active }) else { return }
        ex.responseEnded = true
        if let proto = ex.upgradeProtocol {
            upgradeToRaw(ex, protocol: proto)
            return
        }
        if ex.heldResponse != nil {
            if ex.script?.response == true { runResponseScript(ex) } else { pauseResponse(ex) }
            return
        }
        completeResponse(ex, trailers: trailers)
    }

    private func completeResponse(_ ex: Exchange, trailers: HTTPHeaders?) {
        guard let context else { return }
        let close = ex.closeAfter
        let channel = context.channel
        let written = context.writeAndFlush(wrapOutboundOut(.end(trailers)))
        lastResponseWrite = written
        written.whenComplete { _ in
            if close { channel.close(promise: nil) }
        }
        ex.responseBody?.finish()
        finish(ex, state: .completed, error: nil)
    }

    /// Writes a held response on unchanged (breakpoint skipped) and streams the rest.
    private func releaseHeldResponse(_ ex: Exchange, note: String) {
        guard let context, let held = ex.heldResponse else { return }
        ex.heldResponse = nil
        ex.addNote(note)
        ex.responseBody?.append(Array(held.body.readableBytesView))
        context.write(wrapOutboundOut(.head(held.head)), promise: nil)
        ex.clientGotHead = true
        if held.body.readableBytes > 0 { context.write(wrapOutboundOut(.body(.byteBuffer(held.body))), promise: nil) }
        context.flush()
    }

    private func pauseResponse(_ ex: Exchange) {
        guard let held = ex.heldResponse, let center = config.rules?.breakpoints, let loop = context?.eventLoop else { return }
        let item = BreakpointItem(flowID: ex.record.id, phase: .response, ruleName: ex.breakpoint?.name ?? "",
                                  method: ex.record.method ?? "", url: ex.record.url ?? "", status: Int(held.head.status.code),
                                  headers: held.head.headers.map { HeaderField(name: $0.name, value: $0.value) })
        ex.record.state = .paused
        ex.pausedItem = item.id
        config.sink.record(ex.record)
        let accepted = center.pause(item, body: Data(held.body.readableBytesView)) { [weak self] decision in
            loop.execute { self?.resumeResponse(ex, item: item, decision: decision) }
        }
        if !accepted {
            ex.record.state = .active
            releaseHeldResponse(ex, note: "Breakpoint skipped: too many requests already paused")
            completeResponse(ex, trailers: nil)
        }
    }

    private func resumeResponse(_ ex: Exchange, item: BreakpointItem, decision: BreakpointDecision?) {
        guard let context, let held = ex.heldResponse, exchanges.contains(where: { $0 === ex }) else { return }
        ex.heldResponse = nil
        ex.pausedItem = nil
        ex.record.state = .active
        let edited = config.rules?.breakpoints.takeBody(item.id) ?? Data()
        switch decision {
        case .abort?:
            ex.addNote("Aborted at breakpoint")
            finish(ex, state: .failed, error: "Aborted at breakpoint")
            context.close(promise: nil)
            return
        case nil:
            releaseHeldResponse(ex, note: "Breakpoint timed out")
        case .execute(let edit)?:
            var headers = HTTPHeaders(Self.withoutFraming(edit.headers).map { ($0.name, $0.value) })
            headers.add(name: "Content-Length", value: "\(edited.count)")
            let status = HTTPResponseStatus(statusCode: edit.status ?? Int(held.head.status.code))
            let head = HTTPResponseHead(version: held.head.version, status: status, headers: headers)
            ex.record.statusCode = Int(status.code)
            ex.record.responseHeaders = headers.map { HeaderField(name: $0.name, value: $0.value) }
            ex.record.responseBytes = edited.count
            ex.addNote("Edited at breakpoint")
            ex.responseBody?.append([UInt8](edited))
            context.write(wrapOutboundOut(.head(head)), promise: nil)
            ex.clientGotHead = true
            if !edited.isEmpty { context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: edited)))), promise: nil) }
        }
        completeResponse(ex, trailers: nil)
    }

    fileprivate func upstreamReadComplete() { context?.flush() }

    fileprivate func upstreamClosed() {
        upstream = nil
        upstreamHandler = nil
        let inFlight = exchanges.filter { $0.record.state == .active && !$0.respondedLocally && !$0.responseEnded }
        guard !inFlight.isEmpty else { return }
        if inFlight.contains(where: { $0.responseHeadSent }) {
            failAll(error: "Upstream closed mid-response")
        } else {
            failAll(error: "Upstream closed before responding")
        }
    }

    fileprivate func upstreamWritabilityChanged(_ writable: Bool) {
        if writable, pendingRead { pendingRead = false; context?.read() }
    }

    /// True while an exchange still awaits (or is streaming) a response from upstream.
    fileprivate var hasInFlightExchange: Bool {
        exchanges.contains { $0.record.state == .active && !$0.respondedLocally }
    }

    fileprivate var downstreamWritable: Bool { context?.channel.isWritable ?? false }

    func read(context: ChannelHandlerContext) {
        if let upstream, !upstream.isWritable { pendingRead = true }
        else if upstream == nil && connecting { pendingRead = true } // hold request bodies while dialing
        else { context.read() }
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { upstreamHandler?.downstreamBecameWritable() }
        context.fireChannelWritabilityChanged()
    }

    /// Client channels allow half-closure, so a client closing an HTTP/1 connection only surfaces as `inputClosed`.
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if framing == .http1, let e = event as? ChannelEvent, case .inputClosed = e {
            clientHalfClosed = true
            closeIfClientDone()
        }
        context.fireUserInboundEventTriggered(event)
    }

    /// The client connection: the channel itself, or for an HTTP/2 stream its parent.
    private var connection: Channel? { context.map { $0.channel.parent ?? $0.channel } }

    private func closeIfClientDone() {
        guard clientHalfClosed, !hasInFlightExchange, let channel = context?.channel else { return }
        if let lastResponseWrite { lastResponseWrite.whenComplete { _ in channel.close(promise: nil) } }
        else { channel.close(promise: nil) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        upstream?.close(promise: nil)
        for ex in exchanges where ex.record.state == .active || ex.record.state == .paused {
            finish(ex, state: .failed, error: "Client closed the connection")
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        for ex in exchanges where ex.record.state == .active {
            finish(ex, state: .failed, error: "\(error)")
        }
        context.close(promise: nil)
    }

    // MARK: Helpers

    private func finish(_ ex: Exchange, state: FlowState, error: String?) {
        // Ending while held at a breakpoint: keep what the client sent, and stop the app offering to resume it.
        if let paused = ex.pausedItem {
            ex.pausedItem = nil
            if let held = ex.heldRequest { ex.requestBody?.append(Array(held.body.readableBytesView)) }
            config.rules?.breakpoints.drop(paused)
        }
        ex.record.state = state
        ex.record.error = error
        ex.record.endedAt = Date()
        ex.requestBody?.finish()
        ex.responseBody?.finish()
        config.sink.record(ex.record)
        exchanges.removeAll { $0 === ex }
        if let connection { config.reaper?.end(connection) }
        closeIfClientDone()
    }

    private func failAll(error: String) {
        guard let context else { return }
        var needs502 = false
        for ex in exchanges where ex.record.state == .active {
            if !ex.clientGotHead && !ex.respondedLocally { needs502 = true }
            finish(ex, state: .failed, error: error)
        }
        if needs502 {
            let body = context.channel.allocator.buffer(string: "Passage: \(error)\n")
            var h = HTTPHeaders()
            h.add(name: "content-type", value: "text/plain; charset=utf-8")
            h.add(name: "content-length", value: "\(body.readableBytes)")
            h.add(name: "connection", value: "close")
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .badGateway, headers: h))), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
            let channel = context.channel
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in channel.close(promise: nil) }
        } else {
            context.close(promise: nil)
        }
    }

    /// After a 101 response both sides speak something other than HTTP: splice them.
    private func upgradeToRaw(_ ex: Exchange, protocol proto: String) {
        guard let context, let upstream, let upstreamHandler, let encoder, let decoder else { return }
        let downstreamChannel = context.channel
        ex.record.note = "Upgraded to \(proto)"
        let (down, up) = GlueHandler.matchedPair()
        down.onBytes = { n in ex.record.requestBytes += n }
        up.onBytes = { n in ex.record.responseBytes += n }
        // The session is removed from the pipeline below, so completion must not depend on it.
        let config = self.config
        if proto.lowercased() == "websocket" {
            let tap = WebSocketTap(flowID: ex.record.id, extensions: ex.record.responseHeaders.value(for: "Sec-WebSocket-Extensions"),
                                   sink: config.sink) { note in
                ex.addNote(note)
                config.sink.record(ex.record)
            }
            down.onData = { tap.feed($0, direction: .sent) }
            up.onData = { tap.feed($0, direction: .received) }
        }
        down.onClose = {
            ex.record.state = .completed
            ex.record.endedAt = Date()
            ex.requestBody?.finish()
            ex.responseBody?.finish()
            config.sink.record(ex.record)
        }
        do {
            let downOps = context.pipeline.syncOperations
            try downOps.addHandler(down)
            let upOps = upstream.pipeline.syncOperations
            try upOps.addHandler(up)
            // Remove handlers that expect HTTP types first, so forwarded leftover bytes reach the glue.
            // Decoders forward leftover bytes on removal without a readComplete, so flush once they are gone.
            upOps.removeHandler(upstreamHandler, promise: nil)
            if let (enc, dec) = upstreamHandler.removable {
                let removed = upstream.eventLoop.makePromise(of: Void.self)
                upOps.removeHandler(dec, promise: removed)
                removed.futureResult.whenComplete { _ in downstreamChannel.flush() }
                upOps.removeHandler(enc, promise: nil)
            }
            self.upstreamHandler = nil
            self.upstream = nil
            config.sink.record(ex.record)
            downOps.removeHandler(context: context, promise: nil)
            let removed = downstreamChannel.eventLoop.makePromise(of: Void.self)
            downOps.removeHandler(decoder, promise: removed)
            removed.futureResult.whenComplete { _ in upstream.flush() }
            downOps.removeHandler(encoder, promise: nil)
        } catch {
            finish(ex, state: .failed, error: "Upgrade failed: \(error)")
            context.close(promise: nil)
        }
    }

    private static func stripPort(_ host: String) -> String {
        if host.hasPrefix("["), let end = host.firstIndex(of: "]") { return String(host[host.index(after: host.startIndex)..<end]) }
        if let colon = host.lastIndex(of: ":"), host.firstIndex(of: ":") == colon { return String(host[..<colon]) }
        return host
    }

    private static func snapshot(_ head: HTTPRequestHead) -> HTTPRequestHeadSnapshot {
        HTTPRequestHeadSnapshot(method: head.method.rawValue, uri: head.uri,
                                headers: head.headers.map { HeaderField(name: $0.name, value: $0.value) })
    }

    private static func apply(_ snap: HTTPRequestHeadSnapshot, to head: HTTPRequestHead) -> HTTPRequestHead {
        var out = head
        out.method = HTTPMethod(rawValue: snap.method)
        out.uri = snap.uri
        out.headers = HTTPHeaders(snap.headers.map { ($0.name, $0.value) })
        return out
    }
}

/// Sits at the tail of an upstream pipeline and forwards response parts to the session.
final class UpstreamHandler: ChannelDuplexHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundIn = HTTPClientRequestPart
    typealias OutboundOut = HTTPClientRequestPart

    private weak var session: HTTPProxySession?
    private var context: ChannelHandlerContext?
    private var pendingRead = false
    var removable: (HTTPRequestEncoder, ByteToMessageHandler<HTTPResponseDecoder>)?

    init(session: HTTPProxySession) { self.session = session }

    /// Stops forwarding to the session (the upstream is being replaced, so its close is not an error).
    func detach() { session = nil }

    func handlerAdded(context: ChannelHandlerContext) { self.context = context }
    func handlerRemoved(context: ChannelHandlerContext) { self.context = nil }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): session?.upstreamResponseHead(head)
        case .body(let buffer): session?.upstreamResponseBody(buffer)
        case .end(let trailers): session?.upstreamResponseEnd(trailers)
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) { session?.upstreamReadComplete() }

    /// Half-closure is enabled on upstream channels, so a server closing an idle keep-alive
    /// connection only surfaces as `inputClosed`. Drop the channel so the next request redials.
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let e = event as? ChannelEvent, case .inputClosed = e, session?.hasInFlightExchange != true {
            context.close(promise: nil)
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) { session?.upstreamClosed() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        session?.upstreamWritabilityChanged(context.channel.isWritable)
    }

    func read(context: ChannelHandlerContext) {
        if session?.downstreamWritable == false { pendingRead = true } else { context.read() }
    }

    func downstreamBecameWritable() {
        if pendingRead { pendingRead = false; context?.read() }
    }
}
