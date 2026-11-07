import Foundation
import ProxyModel

/// One sent request kept for Compose's history.
public struct ComposeHistoryItem: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var request: ComposedRequest
    /// The body was larger than `FlowStore.composeHistoryMaxBody` and was not kept.
    public var bodyDropped: Bool

    /// The JSON column: the request without its body (that lives in the `body` blob).
    struct Stored: Codable {
        var request: ComposedRequest
        var bodyDropped: Bool
    }
}
