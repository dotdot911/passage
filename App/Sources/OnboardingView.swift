import SwiftUI

/// First-run setup: what Passage does and what it records (shown before any capture, as guideline 5.4 asks), starting capture, then what to decrypt and the certificate.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [Page] = []
    private let reopened = UserDefaults.standard.bool(forKey: "onboardingDone")

    enum Page: Hashable { case data, capture, https }

    var body: some View {
        NavigationStack(path: $path) {
            welcome
                .navigationDestination(for: Page.self) { page in
                    switch page {
                    case .data: data
                    case .capture: capture
                    case .https: OnboardingHTTPSPage(finish: finish)
                    }
                }
        }
    }

    private var welcome: some View {
        page {
            TrafficPreview()
            heading("See what your apps send", "Passage is a debugging proxy that runs on your iPhone. No Mac, no cables.")
            VStack(alignment: .leading, spacing: 14) {
                point("Read it", "Headers, bodies, JSON, GraphQL and WebSocket messages.")
                point("Change it", "Edit a request at a breakpoint, or answer it with a local file.")
                point("Send it again", "Replay any request, or write one in Compose.")
            }
        } button: {
            primary("Continue") { path.append(.data) }
        }
        .toolbar {
            // Reopened from Settings: the guide is optional now, so it can be closed from its first page.
            if reopened { ToolbarItem(placement: .cancellationAction) { CloseButton { model.showOnboarding = false } } }
        }
    }

    /// What Passage records and where it goes, shown before capture can start, as guideline 5.4 asks.
    private var data: some View {
        page {
            heading("Your traffic stays on this iPhone", nil)
            VStack(alignment: .leading, spacing: 14) {
                point("What it records", "The address, headers and body of each request and response, while the proxy is on.")
                point("Where it’s kept", "On this iPhone only. There’s no Passage server, account or analytics.")
                point("When it leaves", "Only when you share or export it. Clear Traffic in Passage’s Settings deletes it.")
                point("HTTPS", "Stays encrypted until you pick a host to decrypt.")
                point("DNS", "Lookups go to Cloudflare (1.1.1.1) and Google (8.8.8.8). Everything else goes straight to its server.")
            }
        } button: {
            primary("Continue") { path.append(.capture) }
        }
        // The welcome page has nothing to go back for, and Back would sit right next to Not Now.
        .navigationBarBackButtonHidden()
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Not Now", action: finish) } }
    }

    /// The screen right before iOS asks to add the VPN configuration: one way forward, as HIG asks for pre-permission screens.
    private var capture: some View {
        let running = model.tunnel.isRunning
        return page {
            VPNPromptPreview(running: running)
            heading(running ? "The proxy is on" : "Turn on the proxy",
                    running
                    ? "Passage is recording. iOS shows VPN in the status bar while it runs. Stop it any time from Traffic or Settings."
                    : "iOS treats the proxy as a VPN, so it asks once before adding it. Tap Allow. Each request still goes straight to its server; there is no VPN server.")
            if let error = model.tunnel.lastError {
                Text(error).foregroundStyle(.statusError)
            }
        } button: {
            if running {
                primary("Continue") { path.append(.https) }
            } else {
                primary("Turn On") { Task { await model.toggleTunnel() } }
                    .disabled(model.tunnel.isBusy)
            }
        }
        .animation(.default, value: running)
    }

    /// Content centered on the screen, scrolling only when it doesn't fit, with the button pinned below it.
    @ViewBuilder
    private func page(@ViewBuilder content: () -> some View, @ViewBuilder button: () -> some View) -> some View {
        let content = content()
        let pinned = button().padding(.horizontal, 24).padding(.bottom, 8)
        let scroll = GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) { content }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 560, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .themedBackground()
        // On iOS 26 the bar takes the background of the screen or sheet under it.
        if #available(iOS 26, *) {
            scroll.safeAreaBar(edge: .bottom) { pinned }
        } else {
            scroll.safeAreaInset(edge: .bottom) { pinned.background(Color.ground) }
        }
    }

    private func heading(_ title: String, _ subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.app(.largeTitle, weight: .bold)).accessibilityAddTraits(.isHeader)
            if let subtitle { Text(subtitle).foregroundStyle(.secondary) }
        }
    }

    private func point(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.app(.headline))
            Text(text).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity) }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "onboardingDone")
        model.showOnboarding = false
    }
}

/// A few made-up rows in the style of the Traffic list, filling in one by one.
private struct TrafficPreview: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = 0

    private static let rows: [(method: String, host: String, path: String, status: Int)] = [
        ("GET", "api.github.com", "/user/repos", 200),
        ("POST", "shop.example.com", "/graphql", 200),
        ("DELETE", "api.example.com", "/v1/session", 401),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(Self.rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Divider().padding(.leading, 14) }
                HStack(spacing: 10) {
                    Text(row.method)
                        .font(.mono(.caption2).bold())
                        .foregroundStyle(.tint)
                        .frame(width: 48, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.host).font(.app(.caption, weight: .bold))
                        Text(row.path).font(.mono(.caption)).foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(String(row.status))
                        .font(.app(.caption).monospacedDigit().bold())
                        .foregroundStyle(color(row.status))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .opacity(index < shown ? 1 : 0)
                .offset(y: index < shown ? 0 : 6)
            }
        }
        .padding(.vertical, 4)
        .background(Color.card, in: .rect(cornerRadius: 20))
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .accessibilityHidden(true)
        .task {
            if reduceMotion { shown = Self.rows.count; return }
            for i in 1...Self.rows.count {
                try? await Task.sleep(for: .milliseconds(i == 1 ? 250 : 180))
                withAnimation(.snappy) { shown = i }
            }
        }
    }

    private func color(_ status: Int) -> Color {
        switch status {
        case 200..<300: .statusSuccess
        default: .statusWarning
        }
    }
}

/// A sketch of the iOS prompt the next tap brings up, or a capturing state once it's allowed.
private struct VPNPromptPreview: View {
    let running: Bool

    var body: some View {
        Group {
            if running {
                HStack(spacing: 10) {
                    Circle().fill(.statusSuccess).frame(width: 10, height: 10)
                    Text("Proxy On").font(.app(.headline))
                    Spacer()
                    Text("VPN").font(.app(.caption, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary))
                        .foregroundStyle(.secondary)
                }
                .padding(18)
                .background(Color.card, in: .rect(cornerRadius: 20))
            } else {
                VStack(spacing: 0) {
                    VStack(spacing: 6) {
                        Text("“Passage” Would Like to Add VPN Configurations").font(.app(.headline)).multilineTextAlignment(.center)
                        Text("All network activity on this iPhone may be filtered or monitored when using VPN.")
                            .font(.app(.footnote)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(20)
                    Divider()
                    HStack(spacing: 0) {
                        Text("Allow").bold().foregroundStyle(.tint).frame(maxWidth: .infinity)
                        Divider().frame(height: 44)
                        Text("Don’t Allow").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    }
                }
                .frame(maxWidth: 300)
                .background(Color.card, in: .rect(cornerRadius: 24))
                .frame(maxWidth: .infinity)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .accessibilityHidden(true)
        .transition(.opacity)
    }
}

/// The last page: which hosts to decrypt, then installing the certificate.
private struct OnboardingHTTPSPage: View {
    @Environment(AppModel.self) private var model
    let finish: () -> Void

    var body: some View {
        AppList {
            Section {
                Text("To read HTTPS, Passage needs its own certificate, made on this iPhone and trusted in Settings. You choose which hosts it decrypts.")
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            }
            Section {
                Picker("What to Decrypt", selection: Binding(get: { model.decryptAll }, set: { all in
                    if all { model.seedDecryptAllDefaults() }
                    model.saveSSLProxying(hosts: model.sslProxyingHosts, decryptAll: all)
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Selected Hosts")
                        Text("Recommended. Pick hosts in Traffic as you go.").font(.app(.caption)).foregroundStyle(.secondary)
                    }
                    .tag(false)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("All Hosts")
                        Text("Apps that pin their certificates will stop connecting.").font(.app(.caption)).foregroundStyle(.secondary)
                    }
                    .tag(true)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: { Text("What to Decrypt") }
            CertificateSteps()
        }
        .navigationTitle("Decrypt HTTPS")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(model.caTrusted == true ? "Done" : "Not Now", action: finish)
            }
        }
        .task { await model.checkTrust() }
    }
}
