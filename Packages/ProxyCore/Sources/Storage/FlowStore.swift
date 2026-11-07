import Foundation
import GRDB
import ProxyModel

extension FlowRecord: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "flow"
}

/// The shared SQLite database (WAL) in the App Group. The extension writes, the app reads.
public final class FlowStore: Sendable {
    public let pool: DatabasePool
    public let bodies: BodyStore
    public let directory: URL

    /// - Parameters:
    ///   - directory: the App Group container (or a temp dir in tests).
    ///   - readerCount: maximum concurrent reader connections (each has its own page cache).
    ///   - smallCache: caps each connection's page cache at 512 KB (the memory-limited extension).
    public init(directory: URL, readerCount: Int = 5, smallCache: Bool = false) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.maximumReaderCount = readerCount
        config.prepareDatabase { db in
            if smallCache { try db.execute(sql: "PRAGMA cache_size = -512") }
            db.add(function: RegexCache.function)
        }
        // The app and the extension share this file. iOS kills a suspended process that holds
        // a lock in a shared container (0xdead10cc); GRDB releases locks when told to suspend.
        config.observesSuspensionNotifications = true
        pool = try DatabasePool(path: directory.appendingPathComponent("flows.sqlite").path, configuration: config)
        bodies = BodyStore(directory: directory.appendingPathComponent("bodies", isDirectory: true))
        try Self.migrator.migrate(pool)
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "flow") { t in
                t.column("id", .blob).primaryKey()
                t.column("startedAt", .datetime).notNull().indexed()
                t.column("endedAt", .datetime)
                t.column("kind", .text).notNull()
                t.column("state", .text).notNull()
                t.column("host", .text).notNull().indexed()
                t.column("ip", .text).notNull()
                t.column("port", .integer).notNull()
                t.column("method", .text)
                t.column("url", .text)
                t.column("statusCode", .integer)
                t.column("requestHeaders", .jsonText).notNull()
                t.column("responseHeaders", .jsonText).notNull()
                t.column("requestBytes", .integer).notNull()
                t.column("responseBytes", .integer).notNull()
                t.column("connectMs", .double)
                t.column("ttfbMs", .double)
                t.column("error", .text)
                t.column("note", .text)
            }
            try db.create(table: "pinnedHost") { t in
                t.column("host", .text).primaryKey()
                t.column("pinnedAt", .datetime).notNull()
            }
            try db.create(table: "setting") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }
        }
        m.registerMigration("v2") { db in
            try db.create(table: "flowMark") { t in
                t.column("flowID", .blob).primaryKey().references("flow", onDelete: .cascade)
                t.column("color", .text)
                t.column("comment", .text)
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "favoriteHost") { t in
                t.column("host", .text).primaryKey()
                t.column("addedAt", .datetime).notNull()
            }
            try db.create(index: "flow_on_kind", on: "flow", columns: ["kind"])
        }
        m.registerMigration("v3") { db in
            try db.create(table: "composeHistory") { t in
                t.column("id", .blob).primaryKey()
                t.column("createdAt", .datetime).notNull().indexed()
                t.column("request", .jsonText).notNull()
                t.column("body", .blob)
            }
        }
        m.registerMigration("v4") { db in
            try db.create(table: "rule") { t in
                t.column("id", .blob).primaryKey()
                t.column("position", .integer).notNull()
                t.column("json", .text).notNull()
            }
        }
        m.registerMigration("v5") { db in
            try db.alter(table: "flow") { t in
                t.add(column: "httpVersion", .text)
                t.add(column: "graphQL", .text)
            }
            try db.create(table: "wsMessage") { t in
                t.column("flowID", .blob).notNull().references("flow", onDelete: .cascade)
                t.column("seq", .integer).notNull()
                t.column("at", .datetime).notNull()
                t.column("direction", .text).notNull()
                t.column("opcode", .text).notNull()
                t.column("length", .integer).notNull()
                t.column("payload", .blob).notNull()
                t.column("truncated", .boolean).notNull()
                t.primaryKey(["flowID", "seq"])
            }
        }
        m.registerMigration("v6") { db in
            try db.create(table: "apiCollection") { t in
                t.column("id", .blob).primaryKey()
                t.column("importedAt", .datetime).notNull()
                t.column("json", .text).notNull()
            }
        }
        m.registerMigration("v7") { db in
            try db.alter(table: "flow") { t in t.add(column: "client", .text).indexed() }
        }
        return m
    }

    /// Releases SQLite locks before the app is suspended (call on didEnterBackground).
    public static func suspend() { NotificationCenter.default.post(name: Database.suspendNotification, object: nil) }
    /// Call on willEnterForeground.
    public static func resume() { NotificationCenter.default.post(name: Database.resumeNotification, object: nil) }

    // MARK: Flows

    /// Writes flows, then WebSocket messages (whose flows must exist), in one transaction.
    public func upsert(_ flows: [FlowRecord], messages: [WebSocketMessage] = []) throws {
        guard !flows.isEmpty || !messages.isEmpty else { return }
        try pool.write { db in
            for f in flows { try f.upsert(db) }
            for m in messages {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO wsMessage (flowID, seq, at, direction, opcode, length, payload, truncated)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [m.flowID, m.seq, m.at, m.direction.rawValue, m.opcode.rawValue, m.length, m.payload, m.truncated])
            }
        }
    }

    /// A flow's WebSocket messages in order.
    public func webSocketMessages(flowID: UUID) throws -> [WebSocketMessage] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM wsMessage WHERE flowID = ? ORDER BY seq", arguments: [flowID]).compactMap { row in
                guard let direction = WebSocketDirection(rawValue: row["direction"]),
                      let opcode = WebSocketOpcode(rawValue: row["opcode"]) else { return nil }
                return WebSocketMessage(flowID: row["flowID"], seq: row["seq"], at: row["at"], direction: direction, opcode: opcode,
                                        length: row["length"], payload: row["payload"], truncated: row["truncated"])
            }
        }
    }

    /// How many WebSocket messages each of `flowIDs` has.
    public func webSocketMessageCounts() throws -> [UUID: Int] {
        try pool.read { db in
            var out: [UUID: Int] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT flowID, COUNT(*) AS n FROM wsMessage GROUP BY flowID") {
                out[row["flowID"]] = row["n"]
            }
            return out
        }
    }

    /// Flows matching `filter`, newest first.
    public func flows(_ filter: FlowFilter = FlowFilter(), limit: Int = 1000) throws -> [FlowRecord] {
        try filter.validate()
        let (clause, args) = filter.whereClause()
        return try pool.read { db in
            try FlowRecord.fetchAll(db, sql: "SELECT * FROM flow WHERE \(clause) ORDER BY startedAt DESC LIMIT ?",
                                    arguments: args + [limit])
        }
    }

    /// One row per host among flows matching `filter` (its `host` is ignored): favorites first, then most recent.
    public func domainSummaries(_ filter: FlowFilter = FlowFilter()) throws -> [DomainSummary] {
        try filter.validate()
        let (clause, args) = filter.whereClause(includeHost: false)
        return try pool.read { db in
            try DomainSummary.fetchAll(db, sql: """
                SELECT host, COUNT(*) AS count, MAX(startedAt) AS lastAt,
                       SUM(IFNULL(statusCode, 0) >= 400 OR (state = 'failed' AND NOT \(Self.clientTLSFailure))) AS errorCount,
                       SUM(state = 'failed' AND \(Self.clientTLSFailure)) AS tlsFailureCount,
                       host IN (SELECT host FROM favoriteHost) AS isFavorite
                FROM flow WHERE \(clause) GROUP BY host ORDER BY isFavorite DESC, lastAt DESC
                """, arguments: args)
        }
    }

    /// One row per app among flows matching `filter` (its `client` is ignored), most recent first.
    public func clientSummaries(_ filter: FlowFilter = FlowFilter()) throws -> [ClientSummary] {
        try filter.validate()
        var all = filter
        all.client = nil
        let (clause, args) = all.whereClause(includeHost: false)
        return try pool.read { db in
            try ClientSummary.fetchAll(db, sql: """
                SELECT client, COUNT(*) AS count, MAX(startedAt) AS lastAt
                FROM flow WHERE client IS NOT NULL AND \(clause) GROUP BY client ORDER BY lastAt DESC
                """, arguments: args)
        }
    }

    /// An HTTPS flow with no decrypted request: a CONNECT tunnel or a failed TLS handshake.
    static let undecrypted = "(kind = 'https' AND IFNULL(method, 'CONNECT') = 'CONNECT')"
    /// An undecrypted connection the client dropped; a server that never finished its handshake is an ordinary error.
    static let clientTLSFailure = "(\(undecrypted) AND IFNULL(error, '') NOT LIKE '\(FlowRecord.upstreamTLSPrefix)%')"

    /// How many flows `filter` hides only because they go to Apple services (0 when those are shown).
    public func hiddenAppleServiceCount(_ filter: FlowFilter, includeHost: Bool = true) throws -> Int {
        guard filter.hideAppleServices, filter.session == nil else { return 0 }
        try filter.validate()
        var shown = filter
        shown.hideAppleServices = false
        let (clause, args) = shown.whereClause(includeHost: includeHost)
        let apple = FlowFilter.appleServiceCondition
        return try pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM flow WHERE \(clause) AND \(apple.sql)", arguments: args + apple.arguments) ?? 0
        }
    }

    public func flow(id: UUID) throws -> FlowRecord? {
        try pool.read { db in try FlowRecord.fetchOne(db, key: id) }
    }

    public func deleteAllFlows() throws {
        try pool.write { db in _ = try FlowRecord.deleteAll(db) }
        try bodies.removeAll()
    }

    /// Body files without a flow row younger than this may still be waiting for their row.
    public static let orphanGracePeriod: TimeInterval = 600

    /// Brings bodies down to at most `maxBytes`: first removes body files whose flow is gone,
    /// then deletes the oldest finished flows. Flows still in progress are never deleted.
    /// - Returns: the number of flows deleted.
    @discardableResult
    public func enforceQuota(maxBytes: Int, now: Date = Date()) throws -> Int {
        var used = bodies.totalSize()
        guard used > maxBytes else { return 0 }

        let known = try pool.read { db in Set(try UUID.fetchAll(db, sql: "SELECT id FROM flow")) }
        for file in bodies.files() where now.timeIntervalSince(file.modified) > Self.orphanGracePeriod {
            guard file.flowID.map({ !known.contains($0) }) ?? true else { continue }
            if (try? FileManager.default.removeItem(at: file.url)) != nil { used -= file.size }
        }

        var deleted = 0
        while used > maxBytes {
            let oldest: [UUID] = try pool.read { db in
                try UUID.fetchAll(db, sql: "SELECT id FROM flow WHERE state != 'active' ORDER BY startedAt ASC LIMIT 200")
            }
            if oldest.isEmpty { break }
            var victims: [UUID] = []
            for id in oldest where used > maxBytes {
                used -= bodies.remove(flowID: id)
                victims.append(id)
            }
            try pool.write { db in _ = try FlowRecord.deleteAll(db, keys: victims) }
            deleted += victims.count
        }
        return deleted
    }

    // MARK: Marks and favorites

    public func marks() throws -> [UUID: FlowMark] {
        try pool.read { db in
            var out: [UUID: FlowMark] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT flowID, color, comment FROM flowMark") {
                let color = (row["color"] as String?).flatMap(MarkColor.init(rawValue:))
                out[row["flowID"]] = FlowMark(color: color, comment: row["comment"])
            }
            return out
        }
    }

    /// Saves a mark; an empty mark deletes it.
    public func setMark(_ mark: FlowMark, for flowID: UUID) throws {
        try pool.write { db in
            if mark.isEmpty {
                try db.execute(sql: "DELETE FROM flowMark WHERE flowID = ?", arguments: [flowID])
            } else {
                try db.execute(sql: "INSERT OR REPLACE INTO flowMark (flowID, color, comment, updatedAt) VALUES (?, ?, ?, ?)",
                               arguments: [flowID, mark.color?.rawValue, mark.comment, Date()])
            }
        }
    }

    public func favoriteHosts() throws -> Set<String> {
        try pool.read { db in Set(try String.fetchAll(db, sql: "SELECT host FROM favoriteHost")) }
    }

    public func setFavorite(_ host: String, _ favorite: Bool) throws {
        try pool.write { db in
            if favorite {
                try db.execute(sql: "INSERT OR REPLACE INTO favoriteHost (host, addedAt) VALUES (?, ?)", arguments: [host, Date()])
            } else {
                try db.execute(sql: "DELETE FROM favoriteHost WHERE host = ?", arguments: [host])
            }
        }
    }

    // MARK: Rules

    /// Map Local bodies: `<container>/rules/<rule id>.body`.
    public var rulesDirectory: URL { directory.appendingPathComponent("rules", isDirectory: true) }
    /// Bodies held at breakpoints: `<container>/breakpoints/<item id>.body`.
    public var breakpointsDirectory: URL { directory.appendingPathComponent("breakpoints", isDirectory: true) }

    public func ruleBodyURL(_ id: UUID) -> URL { rulesDirectory.appendingPathComponent("\(id.uuidString).body") }
    /// A script rule's code.
    public func ruleScriptURL(_ id: UUID) -> URL { rulesDirectory.appendingPathComponent("\(id.uuidString).js") }

    /// The code of every script rule that has its file.
    public func scriptSources() -> [ScriptSource] {
        ((try? rules()) ?? []).filter { $0.tool == .script }.compactMap { rule in
            (try? String(contentsOf: ruleScriptURL(rule.id), encoding: .utf8)).map { ScriptSource(id: rule.id, name: rule.name, code: $0) }
        }
    }

    /// All rules in display order.
    public func rules() throws -> [Rule] {
        try pool.read { db in
            try String.fetchAll(db, sql: "SELECT json FROM rule ORDER BY position").compactMap {
                try? JSONDecoder().decode(Rule.self, from: Data($0.utf8))
            }
        }
    }

    /// Updates a rule in place, or appends a new one at the end.
    public func saveRule(_ rule: Rule) throws {
        let json = String(decoding: try JSONEncoder().encode(rule), as: UTF8.self)
        try pool.write { db in
            if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rule WHERE id = ?", arguments: [rule.id]) == 1 {
                try db.execute(sql: "UPDATE rule SET json = ? WHERE id = ?", arguments: [json, rule.id])
            } else {
                let next = try Int.fetchOne(db, sql: "SELECT IFNULL(MAX(position) + 1, 0) FROM rule") ?? 0
                try db.execute(sql: "INSERT INTO rule (id, position, json) VALUES (?, ?, ?)", arguments: [rule.id, next, json])
            }
        }
    }

    /// Deletes a rule and its body or script file.
    public func deleteRule(id: UUID) throws {
        try pool.write { db in try db.execute(sql: "DELETE FROM rule WHERE id = ?", arguments: [id]) }
        try? FileManager.default.removeItem(at: ruleBodyURL(id))
        try? FileManager.default.removeItem(at: ruleScriptURL(id))
    }

    /// Rewrites positions so `ids` come first in this order; the others keep their relative order after them.
    public func setRuleOrder(_ ids: [UUID]) throws {
        try pool.write { db in
            let all = try UUID.fetchAll(db, sql: "SELECT id FROM rule ORDER BY position")
            let ordered = ids.filter(all.contains) + all.filter { !ids.contains($0) }
            for (i, id) in ordered.enumerated() {
                try db.execute(sql: "UPDATE rule SET position = ? WHERE id = ?", arguments: [i, id])
            }
        }
    }

    // MARK: API collections

    /// Imported OpenAPI collections, newest first.
    public func apiCollections() throws -> [APICollection] {
        try pool.read { db in
            try String.fetchAll(db, sql: "SELECT json FROM apiCollection ORDER BY importedAt DESC").compactMap {
                try? JSONDecoder().decode(APICollection.self, from: Data($0.utf8))
            }
        }
    }

    public func saveAPICollection(_ collection: APICollection) throws {
        let json = String(decoding: try JSONEncoder().encode(collection), as: UTF8.self)
        try pool.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO apiCollection (id, importedAt, json) VALUES (?, ?, ?)",
                           arguments: [collection.id, collection.importedAt, json])
        }
    }

    public func deleteAPICollection(id: UUID) throws {
        try pool.write { db in try db.execute(sql: "DELETE FROM apiCollection WHERE id = ?", arguments: [id]) }
    }

    // MARK: Compose history

    public static let composeHistoryLimit = 50
    /// Bodies larger than this are not kept in the history.
    public static let composeHistoryMaxBody = 1024 * 1024

    /// Saves a sent request and keeps only the newest `composeHistoryLimit`.
    public func addComposeHistory(_ request: ComposedRequest, at date: Date = Date()) throws {
        var meta = request
        let body = request.body.flatMap { $0.count <= Self.composeHistoryMaxBody ? $0 : nil }
        meta.body = nil
        let json = String(decoding: try JSONEncoder().encode(ComposeHistoryItem.Stored(request: meta, bodyDropped: request.body != nil && body == nil)), as: UTF8.self)
        try pool.write { db in
            try db.execute(sql: "INSERT INTO composeHistory (id, createdAt, request, body) VALUES (?, ?, ?, ?)",
                           arguments: [UUID(), date, json, body])
            try db.execute(sql: """
                DELETE FROM composeHistory WHERE id NOT IN (SELECT id FROM composeHistory ORDER BY createdAt DESC LIMIT ?)
                """, arguments: [Self.composeHistoryLimit])
        }
    }

    /// Newest first.
    public func composeHistory() throws -> [ComposeHistoryItem] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id, createdAt, request, body FROM composeHistory ORDER BY createdAt DESC").compactMap { row in
                let json: String = row["request"]
                guard let stored = try? JSONDecoder().decode(ComposeHistoryItem.Stored.self, from: Data(json.utf8)) else { return nil }
                var request = stored.request
                request.body = row["body"]
                return ComposeHistoryItem(id: row["id"], createdAt: row["createdAt"], request: request, bodyDropped: stored.bodyDropped)
            }
        }
    }

    public func deleteComposeHistory(id: UUID) throws {
        try pool.write { db in try db.execute(sql: "DELETE FROM composeHistory WHERE id = ?", arguments: [id]) }
    }

    // MARK: Pinned hosts

    public func pinnedHosts() throws -> Set<String> {
        try pool.read { db in Set(try String.fetchAll(db, sql: "SELECT host FROM pinnedHost")) }
    }

    public func setPinned(_ host: String, _ pinned: Bool) throws {
        try pool.write { db in
            if pinned {
                try db.execute(sql: "INSERT OR REPLACE INTO pinnedHost (host, pinnedAt) VALUES (?, ?)", arguments: [host, Date()])
            } else {
                try db.execute(sql: "DELETE FROM pinnedHost WHERE host = ?", arguments: [host])
            }
        }
    }

    // MARK: Settings

    public func setting<T: Codable>(_ key: SettingKey<T>) throws -> T {
        let json: String? = try pool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [key.name])
        }
        guard let json, let value = try? JSONDecoder().decode(T.self, from: Data(json.utf8)) else { return key.defaultValue }
        return value
    }

    public func setSetting<T: Codable>(_ key: SettingKey<T>, _ value: T) throws {
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try pool.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO setting (key, value) VALUES (?, ?)", arguments: [key.name, json])
        }
    }
}

/// A typed settings key with its default.
public struct SettingKey<T: Codable>: Sendable where T: Sendable {
    public let name: String
    public let defaultValue: T
    public init(_ name: String, default defaultValue: T) { self.name = name; self.defaultValue = defaultValue }
}

public enum Settings {
    /// Hosts decrypted when `decryptAllHosts` is off. A leading "*." matches any subdomain.
    public static let sslProxyingHosts = SettingKey<[String]>("sslProxyingHosts", default: [])
    /// Decrypt every host except `excludedHosts` (off by default: nothing is decrypted until the user opts in).
    public static let decryptAllHosts = SettingKey<Bool>("decryptAllHosts", default: false)
    /// Hosts never decrypted. A leading "*." matches any subdomain.
    public static let excludedHosts = SettingKey<[String]>("excludedHosts", default: [])
    /// Tools whose global switch is on.
    public static let enabledTools = SettingKey<Set<RuleTool>>("enabledTools", default: RuleTool.enabledByDefault)
    /// Stop decrypting a host after its clients reject our certificate twice (off by default).
    public static let autoPinning = SettingKey<Bool>("autoPinning", default: false)
    /// Body storage quota in bytes (default 2 GB).
    public static let quotaBytes = SettingKey<Int>("quotaBytes", default: 2 * 1024 * 1024 * 1024)
    /// Why the tunnel last stopped (`NEProviderStopReason` raw value), shown by the app.
    public static let lastStop = SettingKey<StopInfo?>("lastStop", default: nil)
    /// Decrypted connections may use HTTP/2 when the client and the server both offer it.
    public static let http2Enabled = SettingKey<Bool>("http2Enabled", default: true)
    /// Max body size passed to hooks that need the full body (sub-project 3).
    public static let maxHookBodyBytes = SettingKey<Int>("maxHookBodyBytes", default: 10 * 1024 * 1024)
}

public struct StopInfo: Codable, Equatable, Sendable {
    public var reason: Int
    public var at: Date
    public init(reason: Int, at: Date) { self.reason = reason; self.at = at }
}
