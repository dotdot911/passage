import ProxyModel
import SwiftUI
import Viewing

/// "Copy as…": the request as cURL, Swift, Python, JavaScript or Kotlin.
struct CodeSheet: View {
    let request: ComposedRequest
    @AppStorage("codeLanguage") private var language = CodeLanguage.curl
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        let code = CodeGenerator.generate(request, language: language)
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Language", selection: $language) {
                    ForEach(CodeLanguage.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .padding()
                ReadOnlyTextView(text: code)
            }
            .navigationTitle("Copy as \(language.rawValue)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { CloseButton { dismiss() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    ShareLink(item: code)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = code
                        copied = true
                    } label: { Label(copied ? "Copied" : "Copy", symbol: copied ? .check : .contentCopy) }
                    .buttonStyle(.borderedProminent)
                }
            }
            .onChange(of: language) { copied = false }
        }
    }
}
