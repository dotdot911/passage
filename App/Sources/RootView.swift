import ProxyModel
import Storage
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        @Bindable var model = model
        Group {
            // A tab bar only: floating at the top in regular width, at the bottom in compact width; no sidebar.
            if #available(iOS 18, *) {
                TabView(selection: $model.tab) {
                    Tab("Traffic", symbol: .traffic, value: AppTab.traffic) { TrafficTab().tabChrome() }
                        .badge(model.pausedBreakpoints.count)
                    Tab("Compose", symbol: .send, value: AppTab.compose) { ComposeTab().tabChrome() }
                    Tab("Rules", symbol: .rules, value: AppTab.rules) { RulesTab().tabChrome() }
                    Tab("Settings", symbol: .settings, value: AppTab.settings) {
                        SettingsTab().tabChrome()
                    }
                }
                .tabViewStyle(.tabBarOnly)
            } else {
                TabView(selection: $model.tab) {
                    TrafficTab().tabChrome()
                        .tabItem { Label("Traffic", symbol: .traffic) }
                        .badge(model.pausedBreakpoints.count)
                        .tag(AppTab.traffic)
                    ComposeTab().tabChrome()
                        .tabItem { Label("Compose", symbol: .send) }
                        .tag(AppTab.compose)
                    RulesTab().tabChrome()
                        .tabItem { Label("Rules", symbol: .rules) }
                        .tag(AppTab.rules)
                    SettingsTab().tabChrome()
                        .tabItem { Label("Settings", symbol: .settings) }
                        .tag(AppTab.settings)
                }
            }
        }
        .sensoryFeedback(.warning, trigger: model.pausedBreakpoints.count) { old, new in new > old }
        .sensoryFeedback(.impact, trigger: model.tunnel.isRunning)
        .sheet(isPresented: $model.showCertificateGuide) { CertificateGuideView() }
        .sheet(isPresented: $model.showHTTPSSettings) { HTTPSSheet() }
        // A welcome sheet in regular width, like Passwords and Reminders on iPad; the whole screen on iPhone.
        .fullScreenCover(isPresented: onboarding(regular: false)) { OnboardingView() }
        .sheet(isPresented: onboarding(regular: true)) { OnboardingView().interactiveDismissDisabled() }
        .sheet(item: $model.codeSheet) { CodeSheet(request: $0.request) }
        .sheet(item: $model.sharedFile) { ShareSheet(items: $0.items).ignoresSafeArea().presentationDetents([.medium, .large]) }
        .sheet(item: $model.ruleDraft) { RuleEditor(draft: $0) }
        // One sheet for every paused message, so stepping between them swaps the content instead of re-presenting.
        .sheet(isPresented: Binding(get: { model.editingBreakpoint != nil }, set: { if !$0 { model.editingBreakpoint = nil } })) {
            if let item = model.editingBreakpoint { BreakpointSheet(item: item) }
        }
        .alert(model.commentTarget.flatMap { model.marks[$0.id]?.comment }?.isEmpty == false ? "Edit Comment" : "Add Comment", isPresented: Binding(get: { model.commentTarget != nil }, set: { if !$0 { model.commentTarget = nil } }),
               presenting: model.commentTarget) { flow in
            CommentEditor(flow: flow)
        }
        .background { TouchObserverInstaller { model.holdListUpdates() } }
        .alert(model.alert?.title ?? "", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
               presenting: model.alert) { _ in
            Button("OK", role: .cancel) {}
        } message: { alert in
            if let message = alert.message { Text(message) }
        }
    }
}

extension RootView {
    private func onboarding(regular: Bool) -> Binding<Bool> {
        Binding(get: { model.showOnboarding && (sizeClass == .regular) == regular },
                set: { model.showOnboarding = $0 })
    }
}

extension View {
    /// What every tab shows under its content: the banner for paused breakpoints.
    func tabChrome() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { BreakpointBanner() }
    }
}

/// The HTTPS screen opened from a banner on the Traffic tab.
private struct HTTPSSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            HTTPSSettingsView()
                .toolbar { ToolbarItem(placement: .cancellationAction) { CloseButton { dismiss() } } }
        }
    }
}

/// Alert content for editing a flow's comment.
private struct CommentEditor: View {
    @Environment(AppModel.self) private var model
    let flow: FlowRecord
    @State private var text: String?

    var body: some View {
        let mark = model.marks[flow.id]
        TextField("Comment", text: Binding(get: { text ?? mark?.comment ?? "" }, set: { text = $0 }))
        Button("Save") { model.setMark(FlowMark(color: mark?.color, comment: text ?? mark?.comment), for: flow.id) }
        Button("Cancel", role: .cancel) {}
    }
}
