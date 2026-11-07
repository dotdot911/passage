import ProxyModel

/// One toggle of `FlowFilter` shown as a chip above the flow list.
public enum FilterChip: Hashable, Sendable {
    case status(StatusClass)
    case method(String)
    case content(ContentCategory)
    case kind(FlowKind)
    case pinned
    case marked

    /// Always shown, whatever the filter holds.
    public static let quick: [FilterChip] = [
        .status(.clientError), .status(.serverError), .status(.failed), .content(.json), .method("POST"), .marked,
    ]

    public var title: String {
        switch self {
        case .status(let s):
            switch s {
            case .informational: "1xx"
            case .success: "2xx"
            case .redirect: "3xx"
            case .clientError: "4xx"
            case .serverError: "5xx"
            case .failed: "Failed"
            }
        case .method(let m): m
        case .content(let c):
            switch c {
            case .json: "JSON"
            case .html: "HTML"
            case .image: "Image"
            case .other: "Other type"
            }
        case .kind(let k):
            switch k {
            case .http: "HTTP"
            case .https: "HTTPS"
            case .dns: "DNS"
            case .raw: "Other TCP"
            }
        case .pinned: "Pinned"
        case .marked: "Highlighted"
        }
    }

    public func isOn(in filter: FlowFilter) -> Bool {
        switch self {
        case .status(let s): filter.statusClasses.contains(s)
        case .method(let m): filter.methods.contains(m)
        case .content(let c): filter.contentTypes.contains(c)
        case .kind(let k): filter.kinds.contains(k)
        case .pinned: filter.showPinned
        case .marked: filter.markedOnly
        }
    }

    public func toggle(in filter: inout FlowFilter) {
        let on = !isOn(in: filter)
        switch self {
        case .status(let s): filter.statusClasses.flip(s, on)
        case .method(let m): filter.methods.flip(m, on)
        case .content(let c): filter.contentTypes.flip(c, on)
        case .kind(let k): filter.kinds.flip(k, on)
        case .pinned: filter.showPinned = on
        case .marked: filter.markedOnly = on
        }
    }
}

extension FlowFilter {
    /// Conditions that differ from the default and have no quick chip, then the quick chips.
    public var chips: [FilterChip] {
        let defaults = FlowFilter()
        let kindOrder: [FlowKind] = [.http, .https, .dns, .raw]
        var active: [FilterChip] = kindOrder
            .filter { kinds.contains($0) != defaults.kinds.contains($0) }
            .map(FilterChip.kind)
        if showPinned { active.append(.pinned) }
        active += methods.sorted().map(FilterChip.method)
        active += StatusClass.allCases.filter(statusClasses.contains).map(FilterChip.status)
        active += ContentCategory.allCases.filter(contentTypes.contains).map(FilterChip.content)
        return active.filter { !FilterChip.quick.contains($0) } + FilterChip.quick
    }
}

private extension Set {
    mutating func flip(_ member: Element, _ on: Bool) {
        if on { insert(member) } else { remove(member) }
    }
}
