import Foundation

/// Coarse content type used by the list filter.
public enum ContentCategory: String, Codable, Sendable, CaseIterable {
    case json, html, image, other

    /// Classifies a `Content-Type` header value; nil or anything unrecognised is `.other`.
    public init(contentType: String?) {
        let mime = (contentType ?? "").split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        if mime.contains("json") { self = .json }
        else if mime.contains("html") { self = .html }
        else if mime.hasPrefix("image/") { self = .image }
        else { self = .other }
    }
}

extension Array where Element == HeaderField {
    /// The first value of a header, matched case-insensitively.
    public func value(for name: String) -> String? {
        first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}
