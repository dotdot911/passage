import Storage
import SwiftUI

/// A page Settings opens: pushed on a stack, or shown beside the sidebar in a split view.
enum SettingsPage: Hashable { case capture, https, appearance, storage, scriptReference, about, acknowledgements }

/// Settings on iPhone: one grouped form, with the pages it links to pushed on top.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        AppForm {
            Section {
                CaptureToggle()
                ReconnectToggle()
                NavigationLink { SettingsPage.https.view } label: {
                    LabeledContent { CAStatusLabel() } label: { Text("HTTPS Decryption") }
                }
            } header: { Text("Proxy") } footer: { SectionFooter { CaptureFooter() } }

            Section {
                NavigationLink { SettingsPage.appearance.view } label: { Text("Appearance") }
            }

            StorageSections()

            Section("Help") {
                Button("Setup Guide") { model.showOnboarding = true }
                NavigationLink { SettingsPage.scriptReference.view } label: { Text("Script Reference") }
            }

            Section("About") {
                LabeledContent("Version", value: Self.version)
                NavigationLink { SettingsPage.acknowledgements.view } label: { Text("Acknowledgements") }
            }
        }
        .navigationTitle("Settings")
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

/// Settings on iPad and the open iPhone Duo: pages with icons and a summary value, like the Settings app's sidebar.
private struct SettingsSidebar: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SettingsPage?
    @State private var search = ""
    @State private var quotaGB = 2

    var body: some View {
        AppList(selection: $selection) {
            let general = ["Proxy Capture Reconnect VPN", "HTTPS Decryption Certificate Hosts HTTP/2",
                           "Appearance Dark Light Accent Color Text Size", "Storage Keep Clear Traffic"]
            if general.contains(where: shows) {
                Section {
                    if shows(general[0]) {
                        row(.capture, "Proxy", symbol: .sensors, value: model.tunnel.isRunning ? "On" : "Off")
                    }
                    if shows(general[1]) {
                        row(.https, "HTTPS Decryption", symbol: .lock, value: caStatus)
                    }
                    if shows(general[2]) {
                        row(.appearance, "Appearance", symbol: .sunMoon)
                    }
                    if shows(general[3]) {
                        row(.storage, "Storage", symbol: .hardDrive, value: "\(quotaGB) GB")
                    }
                } header: { Text("General") }
            }
            if shows("Setup Guide") || shows("Script Reference") || shows("About Version Acknowledgements") {
                Section {
                    if shows("Setup Guide") {
                        Button { model.showOnboarding = true } label: { SidebarRow("Setup Guide", symbol: .menuBook) }
                            .themedRow(selected: false)
                    }
                    if shows("Script Reference") {
                        row(.scriptReference, "Script Reference", symbol: .dataObject)
                    }
                    if shows("About Version Acknowledgements") {
                        row(.about, "About", symbol: .info)
                    }
                } header: { Text("Help") }
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
        .navigationTitle("Settings")
        .onAppear(perform: loadQuota)
        .onChange(of: selection) { loadQuota() }
    }

    private func row(_ page: SettingsPage, _ title: LocalizedStringKey, symbol: AppSymbol, value: String? = nil) -> some View {
        SidebarRow(title, symbol: symbol, value: value)
            .tag(page)
            .themedRow(selected: selection == page)
    }

    /// Whether a page matches the search; `terms` are its title and the settings on it.
    private func shows(_ terms: String) -> Bool {
        search.isEmpty || terms.localizedCaseInsensitiveContains(search.trimmingCharacters(in: .whitespaces))
    }

    private var caStatus: String {
        switch (model.caExpiry, model.caTrusted) {
        case (.expired?, _): "Expired"
        case (.expiresSoon?, _): "Expires Soon"
        case (_, true?): "Trusted"
        case (_, false?): "Not Trusted"
        case (_, nil): ""
        }
    }

    private func loadQuota() {
        guard let store = model.store else { return }
        quotaGB = max(1, ((try? store.setting(Settings.quotaBytes)) ?? Settings.quotaBytes.defaultValue) >> 30)
    }
}

/// Capture and Reconnect Automatically on a page of their own.
private struct CapturePage: View {
    var body: some View {
        AppForm {
            Section {
                CaptureToggle()
                ReconnectToggle()
            } footer: { SectionFooter { CaptureFooter() } }
        }
        .navigationTitle("Proxy")
    }
}

/// The tunnel's last error, then what Reconnect Automatically does.
private struct CaptureFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = model.tunnel.lastError { Text(error).foregroundStyle(.statusError) }
            Text("Reconnect Automatically turns the proxy back on after the iPhone restarts. iOS lists Passage as a VPN.")
        }
    }
}

/// Turns capture back on after a restart, through the VPN's on-demand rule.
private struct ReconnectToggle: View {
    @Environment(AppModel.self) private var model
    @State private var onDemand = false
    @State private var loaded = false

    var body: some View {
        Toggle("Reconnect Automatically", isOn: $onDemand)
            .onAppear {
                onDemand = model.tunnel.onDemandEnabled
                loaded = onDemand
            }
            .onChange(of: onDemand) {
                guard onDemand != loaded else { return }
                loaded = onDemand
                Task { await model.tunnel.setOnDemand(onDemand) }
            }
    }
}

/// How much traffic to keep, and clearing it.
private struct StorageSections: View {
    @Environment(AppModel.self) private var model
    @State private var quotaGB = 2
    @State private var loadedQuotaGB = 2
    @State private var confirmClear = false

    var body: some View {
        Section("Storage") {
            Picker("Keep Up To", selection: $quotaGB) {
                ForEach(Set([1, 2, 5, 10, quotaGB]).sorted(), id: \.self) { Text("\($0) GB") }
            }
            .onChange(of: quotaGB) {
                guard quotaGB != loadedQuotaGB else { return }
                loadedQuotaGB = quotaGB
                try? model.store?.setSetting(Settings.quotaBytes, quotaGB << 30)
            }
            Button("Clear Traffic", role: .destructive) { confirmClear = true }
        }
        .onAppear {
            guard let store = model.store else { return }
            quotaGB = max(1, ((try? store.setting(Settings.quotaBytes)) ?? Settings.quotaBytes.defaultValue) >> 30)
            loadedQuotaGB = quotaGB
        }
        .confirmationDialog("Clear all recorded traffic?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear Traffic", role: .destructive) { Task { await model.clearSession() } }
        }
    }
}

/// The app's icon, name and version above its details and the open-source code it is built on.
private struct AboutPage: View {
    var body: some View {
        AppForm {
            Section {
                VStack(spacing: 10) {
                    Image("AboutIcon")
                        .resizable()
                        .frame(width: 96, height: 96)
                        .clipShape(.rect(cornerRadius: 22, style: .continuous))
                        .accessibilityHidden(true)
                    Text("Passage").font(.app(.title2, weight: .bold))
                    Text("A debugging proxy that runs on your iPhone.")
                        .font(.app(.subheadline))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
            }
            Section {
                LabeledContent("Version", value: SettingsView.version)
            }
            Section {
                AcknowledgementRows()
            } header: { Text("Acknowledgements") } footer: {
                SectionFooter { Text("Passage is built on these open-source projects, used under their licenses.") }
            }
        }
        .navigationTitle("About")
    }
}

/// Starts and stops capturing from Settings, like the VPN switch in the Settings app.
private struct CaptureToggle: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        LabeledContent {
            if model.tunnel.isBusy {
                ProgressView()
                    .accessibilityLabel(model.tunnel.isRunning ? "Stopping Proxy" : "Starting Proxy")
            } else {
                Toggle("Proxy", isOn: Binding(get: { model.tunnel.isRunning },
                                                set: { on in if on != model.tunnel.isRunning { Task { await model.toggleTunnel() } } }))
                    .labelsHidden()
            }
        } label: {
            // The page and the section are already titled Proxy.
            Text("Enabled")
        }
    }
}

/// Open-source code Passage is built on.
private struct AcknowledgementsView: View {
    var body: some View {
        AppList { AcknowledgementRows() }
            .navigationTitle("Acknowledgements")
            .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AcknowledgementRows: View {
    private static let items: [(name: String, license: String)] = [
        ("Geist", "SIL Open Font License 1.1"),
        ("GRDB.swift", "MIT License"),
        ("Lucide", "ISC License"),
        ("lwIP", "BSD License"),
        ("swift-certificates", "Apache License 2.0"),
        ("swift-crypto", "Apache License 2.0"),
        ("swift-nio", "Apache License 2.0"),
        ("swift-nio-http2", "Apache License 2.0"),
        ("swift-nio-ssl", "Apache License 2.0"),
        ("Yams", "MIT License"),
        ("Zstandard", "BSD License"),
    ]

    var body: some View {
        ForEach(Self.items, id: \.name) { item in
            LabeledContent(item.name, value: item.license)
        }
    }
}

extension SettingsPage {
    @ViewBuilder var view: some View {
        switch self {
        case .capture: CapturePage()
        case .https: HTTPSSettingsView()
        case .appearance: AppearanceView()
        case .storage: AppForm { StorageSections() }.navigationTitle("Storage")
        case .about: AboutPage()
        case .scriptReference: ScriptReferenceView()
        case .acknowledgements: AcknowledgementsView()
        }
    }
}

/// The Settings tab: a stack in compact width; in regular width the list beside the page picked, like the Settings app.
struct SettingsTab: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var page: SettingsPage? = .capture

    var body: some View {
        Group {
            if sizeClass != .regular {
                NavigationStack { SettingsView() }
            } else {
                NavigationSplitView(columnVisibility: $columns) {
                    SettingsSidebar(selection: $page)
                        .navigationSplitViewColumnWidth(min: 320, ideal: 360, max: 440)
                        .toolbar(removing: .sidebarToggle)
                } detail: {
                    NavigationStack { (page ?? .capture).view.readableWidth().navigationBarTitleDisplayMode(.inline) }
                        .id(page)
                }
                .navigationSplitViewStyle(.balanced)
                .environment(\.inSplitView, true)
            }
        }
    }
}
