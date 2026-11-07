import SwiftUI

/// Walks the user through installing and trusting the root CA (iOS has no API to do it for them).
struct CertificateGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AppList { CertificateSteps() }
                .navigationTitle("Certificate")
                .toolbar { ToolbarItem(placement: .cancellationAction) { CloseButton { dismiss() } } }
        }
    }
}

/// The install-and-trust steps plus a Check button, shared by the guide and onboarding.
struct CertificateSteps: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var checking = false

    var body: some View {
        Section {
            step(1, "Turn on the proxy", done: model.tunnel.isRunning) {
                if !model.tunnel.isRunning { Button("Turn On") { Task { await model.toggleTunnel() } } }
            }
            step(2, "Download the profile in Safari", done: model.caTrusted == true) {
                Button("Open in Safari") { openURL(URL(string: "http://198.18.0.1/ca.mobileconfig")!) }
                    .disabled(!model.tunnel.isRunning)
            }
            step(3, "Settings › General › VPN & Device Management › Passage CA › Install", done: model.caTrusted == true) { EmptyView() }
            step(4, "Settings › General › About › Certificate Trust Settings › turn on Passage CA", done: model.caTrusted == true) { EmptyView() }
        } footer: {
            SectionFooter {
                Text("The certificate and its private key are created on this device and never leave it.")
            }
        }
        Section {
            Button {
                Task {
                    checking = true
                    await model.checkTrust()
                    checking = false
                }
            } label: {
                HStack {
                    Text("Check Trust")
                    Spacer()
                    if checking { ProgressView() }
                    else if model.caTrusted == true { Label("Trusted", symbol: .verifiedFill).foregroundStyle(.statusSuccess) }
                    else if model.caTrusted == false { Label("Not Trusted", symbol: .gppBadFill).foregroundStyle(.statusWarning) }
                }
            }
            .disabled(!model.tunnel.isRunning)
        }
        // Coming back from the Settings app is when the trust may have changed.
        .onChange(of: scenePhase) { if scenePhase == .active { Task { await model.checkTrust() } } }
    }

    private func step<Accessory: View>(_ n: Int, _ text: String, done: Bool, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(symbol: done ? .checkCircleFill : .counter(n))
                .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.tint))
                .font(.app(.title3))
                .accessibilityLabel(done ? "Step \(n), done" : "Step \(n)")
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                accessory()
            }
        }
    }
}
