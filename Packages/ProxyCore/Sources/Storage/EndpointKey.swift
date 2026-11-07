import Foundation

/// Groups URLs by endpoint: the path without the query, with ID-like segments folded into `{id}`.
public enum EndpointKey {
    public static let placeholder = "{id}"

    public static func of(_ url: String) -> String {
        let path = URLComponents(string: url)?.path ?? url
        guard !path.isEmpty, path != "/" else { return "/" }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map { segment in
            isID(segment) ? placeholder : String(segment)
        }
        return segments.joined(separator: "/")
    }

    /// Digits only, a UUID, or hex longer than 16 characters.
    static func isID(_ segment: Substring) -> Bool {
        guard !segment.isEmpty else { return false }
        if segment.allSatisfy(\.isASCIIDigit) { return true }
        if UUID(uuidString: String(segment)) != nil { return true }
        return segment.count > 16 && segment.allSatisfy(\.isHexDigit)
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
