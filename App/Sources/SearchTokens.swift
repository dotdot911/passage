import ProxyModel
import Storage
import SwiftUI

/// A filter condition shown as a token in the search field, a thin face over `FilterChip`.
enum SearchToken: Identifiable, Hashable {
    case chip(FilterChip)
    case regex

    var id: Self { self }

    static let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

    /// Every token, quick ones first, without repeats.
    static let all: [SearchToken] = {
        let candidates = FilterChip.quick.map(SearchToken.chip)
            + methods.map { .chip(.method($0)) }
            + StatusClass.allCases.map { .chip(.status($0)) }
            + ContentCategory.allCases.map { .chip(.content($0)) }
            + [.regex]
        var seen = Set<SearchToken>()
        return candidates.filter { seen.insert($0).inserted }
    }()

    var title: String {
        switch self {
        case .chip(let chip): chip.title
        case .regex: "Regex"
        }
    }

    func isOn(in filter: FlowFilter) -> Bool {
        switch self {
        case .chip(let chip): chip.isOn(in: filter)
        case .regex: filter.isRegex
        }
    }

    func toggle(in filter: inout FlowFilter) {
        switch self {
        case .chip(let chip): chip.toggle(in: &filter)
        case .regex: filter.isRegex.toggle()
        }
    }

    /// The quick tokens for an empty field, otherwise tokens whose title starts with the typed text; "/" offers Regex.
    /// Leaves out tokens already picked and conditions the filter already has.
    static func suggestions(for text: String, picked: [SearchToken], filter: FlowFilter) -> [SearchToken] {
        let off = all.filter { !picked.contains($0) && !$0.isOn(in: filter) }
        let query = text.trimmingCharacters(in: .whitespaces).lowercased()
        if query.isEmpty { return off.filter { if case .chip(let c) = $0 { FilterChip.quick.contains(c) } else { false } } }
        if query == "/" { return off.filter { $0 == .regex } }
        return off.filter { $0.title.lowercased().hasPrefix(query) }
    }
}

/// The flow search field. Tokens narrow this search only; Cancel clears them and the saved filter stays.
struct FlowSearch: ViewModifier {
    @Environment(AppModel.self) private var model
    let prompt: String
    let regexPrompt: String

    #if os(iOS)
    private static let placement = SearchFieldPlacement.navigationBarDrawer(displayMode: .always)
    #else
    private static let placement = SearchFieldPlacement.toolbar
    #endif

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .searchable(
                text: $model.search,
                tokens: tokens,
                placement: Self.placement,
                prompt: model.filter.isRegex || model.searchTokens.contains(.regex) ? regexPrompt : prompt
            ) { token in
                Text(token.title).accessibilityLabel("Filter: \(token.title)")
            }
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .autocorrectionDisabled()
            .searchSuggestions {
                let suggestions = SearchToken.suggestions(for: model.search, picked: model.searchTokens, filter: model.filter)
                if !suggestions.isEmpty {
                    Section("Suggestions") {
                        ForEach(suggestions) { token in
                            Text(token.title).foregroundStyle(.primary).tint(.primary)
                                .searchCompletion(token)
                        }
                    }
                }
            }
    }

    private var tokens: Binding<[SearchToken]> {
        Binding {
            model.searchTokens
        } set: { tokens in
            // A suggestion picked while typing replaces the text that brought it up.
            if tokens.count > model.searchTokens.count { model.search = "" }
            model.searchTokens = tokens
        }
    }
}

extension View {
    func flowSearch(prompt: String, regexPrompt: String) -> some View {
        modifier(FlowSearch(prompt: prompt, regexPrompt: regexPrompt))
    }
}
