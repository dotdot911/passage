import ProxyModel
import Storage
import SwiftUI

struct FilterSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            AppForm {
                Section {
                    Toggle("Search as Regular Expression", isOn: $model.filter.isRegex)
                }
                Section("Show") {
                    toggle("HTTP", .http, in: $model.filter.kinds)
                    toggle("HTTPS", .https, in: $model.filter.kinds)
                    toggle("DNS", .dns, in: $model.filter.kinds)
                    toggle("Other TCP", .raw, in: $model.filter.kinds)
                    Toggle("Pinned Hosts", isOn: $model.filter.showPinned)
                }
                Section("Method") {
                    ForEach(SearchToken.methods, id: \.self) { member($0, $0, in: $model.filter.methods) }
                }
                Section("Status") {
                    member("1xx", StatusClass.informational, in: $model.filter.statusClasses)
                    member("2xx", StatusClass.success, in: $model.filter.statusClasses)
                    member("3xx", StatusClass.redirect, in: $model.filter.statusClasses)
                    member("4xx", StatusClass.clientError, in: $model.filter.statusClasses)
                    member("5xx", StatusClass.serverError, in: $model.filter.statusClasses)
                    member("Failed", StatusClass.failed, in: $model.filter.statusClasses)
                }
                Section("Response Type") {
                    member("JSON", ContentCategory.json, in: $model.filter.contentTypes)
                    member("HTML", ContentCategory.html, in: $model.filter.contentTypes)
                    member("Image", ContentCategory.image, in: $model.filter.contentTypes)
                    member("Other", ContentCategory.other, in: $model.filter.contentTypes)
                }
                Section {
                    Toggle("Highlighted or Commented Only", isOn: $model.filter.markedOnly)
                } footer: {
                    SectionFooter {
                        Text("When nothing is checked in Method, Status or Response Type, every value is shown.")
                    }
                }
            }
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset") { model.filter = FlowFilter() }
                        .disabled(model.filter.isDefault && !model.filter.isRegex)
                }
                ToolbarItem(placement: .confirmationAction) { ConfirmButton { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func toggle<T: Hashable>(_ title: String, _ value: T, in set: Binding<Set<T>>) -> some View {
        Toggle(title, isOn: Binding(
            get: { set.wrappedValue.contains(value) },
            set: { if $0 { set.wrappedValue.insert(value) } else { set.wrappedValue.remove(value) } }
        ))
    }

    /// A row that is checked when `value` is in the set, like the filter options in Mail.
    private func member<T: Hashable>(_ title: String, _ value: T, in set: Binding<Set<T>>) -> some View {
        let on = set.wrappedValue.contains(value)
        return Button {
            if on { set.wrappedValue.remove(value) } else { set.wrappedValue.insert(value) }
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if on { Image(symbol: .check).fontWeight(.semibold).foregroundStyle(.tint) }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
