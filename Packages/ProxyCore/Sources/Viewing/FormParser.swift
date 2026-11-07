import Foundation

public enum FormParser {
    /// Parses `a=1&b=x+y` (a form body or a URL query) in order; `+` is a space, `%XX` is decoded.
    public static func parse(_ text: String) -> [(name: String, value: String)] {
        text.split(separator: "&", omittingEmptySubsequences: true).map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return (decode(parts[0]), parts.count > 1 ? decode(parts[1]) : "")
        }
    }

    static func decode(_ s: Substring) -> String {
        let spaced = s.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }

    /// The query items of a URL string, or an empty list if it has no query.
    public static func query(of url: String) -> [(name: String, value: String)] {
        guard let q = url.firstIndex(of: "?") else { return [] }
        let rest = url[url.index(after: q)...]
        return parse(String(rest.prefix { $0 != "#" }))
    }
}
