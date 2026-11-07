import Foundation

/// Requests generated from an imported OpenAPI or Swagger document, offered in Compose.
public struct APICollection: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var version: String?
    public var baseURL: String
    public var importedAt: Date
    public var requests: [APIRequest]

    public init(id: UUID = UUID(), title: String, version: String?, baseURL: String, importedAt: Date = Date(),
                requests: [APIRequest]) {
        self.id = id
        self.title = title
        self.version = version
        self.baseURL = baseURL
        self.importedAt = importedAt
        self.requests = requests
    }
}

public struct APIRequest: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    /// The operation's first tag, used to group requests; nil when untagged.
    public var tag: String?
    /// `operationId`, or "METHOD path".
    public var name: String
    public var summary: String?
    public var request: ComposedRequest

    public init(id: UUID = UUID(), tag: String?, name: String, summary: String?, request: ComposedRequest) {
        self.id = id
        self.tag = tag
        self.name = name
        self.summary = summary
        self.request = request
    }
}
