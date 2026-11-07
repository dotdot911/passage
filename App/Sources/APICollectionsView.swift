import ProxyModel
import SwiftUI
import UniformTypeIdentifiers

/// One imported API, grouped by tag. Tapping a request opens it in the editor.
struct APICollectionDetail: View {
    let collection: APICollection
    let pick: (APIRequest) -> Void
    @State private var search = ""

    var body: some View {
        let groups = Dictionary(grouping: filtered) { $0.tag ?? "Other" }
        AppList {
            ForEach(groups.keys.sorted(), id: \.self) { tag in
                Section(tag) {
                    ForEach(groups[tag]!) { request in
                        Button { pick(request) } label: {
                            PushRow {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(request.request.method).font(.mono(.caption, weight: .bold))
                                        Text(path(request)).font(.mono(.caption)).lineLimit(1)
                                    }
                                    Text(request.summary ?? request.name).font(.app(.caption)).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                        .tint(.primary)
                    }
                }
            }
        }
        .overlay { if filtered.isEmpty && !search.isEmpty { ContentUnavailableView(searching: search) } }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Name or path")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .navigationTitle(collection.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var filtered: [APIRequest] {
        search.isEmpty ? collection.requests : collection.requests.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.request.url.localizedCaseInsensitiveContains(search)
                || ($0.summary ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    private func path(_ r: APIRequest) -> String {
        r.request.url.hasPrefix(collection.baseURL) ? String(r.request.url.dropFirst(collection.baseURL.count)) : r.request.url
    }
}
