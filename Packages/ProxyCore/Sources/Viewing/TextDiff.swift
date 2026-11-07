import Foundation
import ProxyModel

public struct DiffLine: Equatable, Sendable {
    public enum Kind: Sendable { case same, added, removed }
    public var kind: Kind
    public var text: String
    public init(_ kind: Kind, _ text: String) { self.kind = kind; self.text = text }
}

public enum HeaderChange: Equatable, Sendable {
    case same(name: String, value: String)
    case added(name: String, value: String)
    case removed(name: String, value: String)
    case changed(name: String, old: String, new: String)
}

public enum TextDiff {
    /// Each side is cut to this many lines before comparing.
    public static let maxLines = 20_000

    /// A unified line diff of `old` against `new`.
    /// - Returns: the lines in order, and whether either side was cut at `maxLines`.
    public static func lines(_ old: String, _ new: String) -> (lines: [DiffLine], truncated: Bool) {
        let a = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let b = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let truncated = a.count > maxLines || b.count > maxLines
        let x = Array(a.prefix(maxLines)), y = Array(b.prefix(maxLines))
        let diff = y.difference(from: x)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var out: [DiffLine] = []
        var i = 0, j = 0
        while i < x.count || j < y.count {
            if i < x.count && removed.contains(i) {
                out.append(DiffLine(.removed, x[i])); i += 1
            } else if j < y.count && inserted.contains(j) {
                out.append(DiffLine(.added, y[j])); j += 1
            } else {
                out.append(DiffLine(.same, x[i])); i += 1; j += 1
            }
        }
        return (out, truncated)
    }

    /// Compares headers by name (case-insensitive); repeated names are joined with ", ".
    /// Order: names of `a` as they appear, then names only in `b`.
    public static func headers(_ a: [HeaderField], _ b: [HeaderField]) -> [HeaderChange] {
        let left = CodeGenerator.merged(a), right = CodeGenerator.merged(b)
        let rightByKey = Dictionary(right.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { x, _ in x })
        let leftKeys = Set(left.map { $0.name.lowercased() })
        var out: [HeaderChange] = left.map { l in
            guard let r = rightByKey[l.name.lowercased()] else { return .removed(name: l.name, value: l.value) }
            return r.value == l.value ? .same(name: l.name, value: l.value) : .changed(name: l.name, old: l.value, new: r.value)
        }
        for r in right where !leftKeys.contains(r.name.lowercased()) { out.append(.added(name: r.name, value: r.value)) }
        return out
    }
}
