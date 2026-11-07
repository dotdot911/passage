import SwiftUI
import WebKit

/// Renders HTML with JavaScript off and every network load blocked, so previewing never sends traffic.
struct HTMLSection: View {
    let data: Data

    var body: some View {
        Section {
            OfflineWebView(html: String(decoding: data, as: UTF8.self), scrolls: false)
                .frame(height: 320)
                .listRowInsets(EdgeInsets())
        } footer: {
            SectionFooter {
                Text("To see the source, choose View As › Text.")
            }
        }
    }
}

/// Renders HTML with JavaScript off and every network load blocked.
struct OfflineWebView: UIViewRepresentable {
    let html: String
    /// Off inside a List, which already scrolls; the Body Viewer shows the page full screen instead.
    var scrolls = true

    /// Blocks every URL, then lets only the inline document (about:, data:) through.
    static let rules = """
    [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^about:"},"action":{"type":"ignore-previous-rules"}},
     {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}}]
    """

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.scrollView.isScrollEnabled = scrolls
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "passage.offline",
                                                                encodedContentRuleList: Self.rules) { list, _ in
            guard let list else { return } // Without the rule list nothing is loaded at all.
            view.configuration.userContentController.add(list)
            view.loadHTMLString(html, baseURL: nil)
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        /// Only the initial inline document may load; tapped links do nothing.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.navigationType == .other && action.request.url?.scheme == "about" ? .allow : .cancel)
        }
    }
}
