import Foundation
import ProxyModel
import Yams

/// Turns an OpenAPI 3.x or Swagger 2.0 document (JSON or YAML) into ready-to-send requests.
public enum OpenAPIImporter {
    static let methods = ["get", "put", "post", "delete", "options", "head", "patch", "trace"]
    /// Example bodies built from schemas stop nesting here.
    static let maxSchemaDepth = 8

    public static func importDocument(_ data: Data, fileName: String) throws(ArchiveError) -> APICollection {
        let root = try parse(data)
        guard root["openapi"] != nil || root["swagger"] != nil else {
            throw .wrongFormat("Not an OpenAPI document: there is no \"openapi\" or \"swagger\" field.")
        }
        guard let paths = root["paths"] as? [String: Any] else { throw .wrongFormat("The document has no paths.") }
        let info = root["info"] as? [String: Any]
        let resolver = Resolver(root: root)
        let base = baseURL(root)
        var requests: [APIRequest] = []
        for path in paths.keys.sorted() {
            guard let item = paths[path] as? [String: Any] else { continue }
            let shared = item["parameters"] as? [Any] ?? []
            for method in methods {
                guard let op = item[method] as? [String: Any] else { continue }
                requests.append(request(method: method, path: path, operation: op, shared: shared, base: base,
                                        root: root, resolver: resolver))
            }
        }
        return APICollection(title: info?["title"] as? String ?? fileName, version: info?["version"] as? String,
                             baseURL: base, requests: requests)
    }

    static func parse(_ data: Data) throws(ArchiveError) -> [String: Any] {
        if let json = try? JSONSerialization.jsonObject(with: data), let dict = json as? [String: Any] { return dict }
        let text = String(decoding: data, as: UTF8.self)
        let loaded: Any?
        do { loaded = try Yams.load(yaml: text) } catch { throw .wrongFormat("Not JSON or YAML: \(error)") }
        guard let dict = loaded as? [String: Any] else { throw .wrongFormat("The document is not an object.") }
        return dict
    }

    /// OpenAPI 3: the first server with variables replaced by their defaults. Swagger 2: scheme, host and basePath.
    static func baseURL(_ root: [String: Any]) -> String {
        if let servers = root["servers"] as? [[String: Any]], let first = servers.first, var url = first["url"] as? String {
            for (name, value) in first["variables"] as? [String: Any] ?? [:] {
                if let d = (value as? [String: Any])?["default"] { url = url.replacingOccurrences(of: "{\(name)}", with: "\(d)") }
            }
            return url.hasSuffix("/") ? String(url.dropLast()) : url
        }
        if let host = root["host"] as? String {
            let scheme = (root["schemes"] as? [String])?.first ?? "https"
            let basePath = (root["basePath"] as? String).map { $0 == "/" ? "" : $0 } ?? ""
            return "\(scheme)://\(host)\(basePath)"
        }
        return ""
    }

    static func request(method: String, path: String, operation op: [String: Any], shared: [Any], base: String,
                        root: [String: Any], resolver: Resolver) -> APIRequest {
        var params: [String: [String: Any]] = [:]
        for raw in shared + (op["parameters"] as? [Any] ?? []) {
            guard let p = resolver.resolve(raw), let name = p["name"] as? String, let location = p["in"] as? String else { continue }
            params["\(location):\(name)"] = p
        }
        var urlPath = path
        var query: [URLQueryItem] = []
        var headers: [HeaderField] = []
        var body: Data?
        for key in params.keys.sorted() {
            let p = params[key]!
            let name = p["name"] as! String
            let example = exampleValue(p, resolver: resolver)
            switch p["in"] as? String {
            case "path":
                if let example { urlPath = urlPath.replacingOccurrences(of: "{\(name)}", with: example) }
            case "query":
                if p["required"] as? Bool == true { query.append(URLQueryItem(name: name, value: example ?? "")) }
            case "header":
                headers.append(HeaderField(name: name, value: example ?? ""))
            case "body":
                if let schema = p["schema"] { body = json(sample(schema, resolver: resolver, depth: 0)) }
                headers.append(HeaderField(name: "Content-Type", value: (op["consumes"] as? [String])?.first ?? (root["consumes"] as? [String])?.first ?? "application/json"))
            default: break
            }
        }
        if let rb = resolver.resolve(op["requestBody"]), let content = rb["content"] as? [String: Any] {
            let mediaType = content.keys.first { $0.contains("json") } ?? content.keys.sorted().first
            if let mediaType, let media = content[mediaType] as? [String: Any] {
                headers.append(HeaderField(name: "Content-Type", value: mediaType))
                if let example = media["example"] {
                    body = json(example)
                } else if let examples = media["examples"] as? [String: Any], let first = examples.keys.sorted().first,
                          let value = resolver.resolve(examples[first])?["value"] {
                    body = json(value)
                } else if let schema = media["schema"] {
                    body = json(sample(schema, resolver: resolver, depth: 0))
                }
            }
        }
        var url = base + urlPath
        if !query.isEmpty, var c = URLComponents(string: url) {
            c.queryItems = query
            url = c.string ?? url
        }
        let name = op["operationId"] as? String ?? "\(method.uppercased()) \(path)"
        return APIRequest(tag: (op["tags"] as? [String])?.first, name: name,
                          summary: op["summary"] as? String ?? op["description"] as? String,
                          request: ComposedRequest(method: method.uppercased(), url: url, headers: headers, body: body))
    }

    /// A parameter's `example`, its schema's example or default, or the first enum value, as text.
    static func exampleValue(_ p: [String: Any], resolver: Resolver) -> String? {
        let schema = resolver.resolve(p["schema"]) ?? p
        for value in [p["example"], schema["example"], schema["default"], (schema["enum"] as? [Any])?.first] {
            if let value { return "\(value)" }
        }
        return nil
    }

    /// A plausible value for `schema`: its example or default if any, else one value per type.
    static func sample(_ raw: Any?, resolver: Resolver, depth: Int) -> Any {
        guard depth < maxSchemaDepth, let schema = resolver.resolve(raw) else { return NSNull() }
        if let example = schema["example"] { return example }
        if let value = schema["default"] { return value }
        if let values = schema["enum"] as? [Any], let first = values.first { return first }
        for key in ["allOf"] {
            if let parts = schema[key] as? [Any] {
                var merged: [String: Any] = [:]
                for part in parts {
                    if let object = sample(part, resolver: resolver, depth: depth + 1) as? [String: Any] {
                        merged.merge(object) { a, _ in a }
                    }
                }
                return merged
            }
        }
        for key in ["oneOf", "anyOf"] {
            if let options = schema[key] as? [Any], let first = options.first { return sample(first, resolver: resolver, depth: depth + 1) }
        }
        let type = (schema["type"] as? String) ?? (schema["properties"] != nil ? "object" : nil)
        switch type {
        case "object":
            var out: [String: Any] = [:]
            for (name, property) in schema["properties"] as? [String: Any] ?? [:] {
                out[name] = sample(property, resolver: resolver, depth: depth + 1)
            }
            return out
        case "array":
            return [sample(schema["items"], resolver: resolver, depth: depth + 1)]
        case "integer": return 0
        case "number": return 0.0
        case "boolean": return false
        case "string":
            switch schema["format"] as? String {
            case "date-time": return "2026-01-01T00:00:00Z"
            case "date": return "2026-01-01"
            case "uuid": return "00000000-0000-0000-0000-000000000000"
            case "email": return "user@example.com"
            default: return "string"
            }
        default: return NSNull()
        }
    }

    static func json(_ value: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject([value]) else { return nil }
        let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        return data
    }

    /// Follows local `$ref`s (`#/components/...`, `#/definitions/...`); external references resolve to nil.
    struct Resolver {
        let root: [String: Any]

        func resolve(_ value: Any?) -> [String: Any]? {
            var current = value as? [String: Any]
            var hops = 0
            while let ref = current?["$ref"] as? String {
                hops += 1
                guard hops < 16, ref.hasPrefix("#/") else { return nil }
                var node: Any? = root
                for part in ref.dropFirst(2).split(separator: "/") {
                    let key = part.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
                    node = (node as? [String: Any])?[key]
                }
                current = node as? [String: Any]
            }
            return current
        }
    }
}
