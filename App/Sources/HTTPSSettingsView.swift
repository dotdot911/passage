import CertKit
import Storage
import SwiftUI

/// Everything about decrypting HTTPS: the certificate, which hosts to decrypt, and HTTP/2.
struct HTTPSSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var excluded: [String] = []
    @State private var pinned: [String] = []
    @State private var autoPinning = false
    @State private var http2 = true
    @State private var newHost = ""
    @State private var sslHosts: [String] = []
    @State private var newSSLHost = ""
    @State private var decryptAll = false
    @State private var confirmRegenerate = false
    @State private var error: String?

    var body: some View {
        AppForm {
            Section {
                NavigationLink {
                    AppList { CertificateSteps() }
                        .navigationTitle("Certificate")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    LabeledContent { CAStatusLabel() } label: { Text("Certificate") }
                }
                if let notAfter = model.caNotAfter {
                    LabeledContent("Expires", value: notAfter.formatted(date: .abbreviated, time: .omitted))
                }
                if let warning = model.caExpiryWarning {
                    Label(warning, symbol: .eventBusy)
                        .foregroundStyle(model.caExpiry == .expired ? .red : .orange)
                    Button("Regenerate Certificate", role: .destructive) { confirmRegenerate = true }
                }
            } footer: {
                SectionFooter {
                    Text("iOS must trust the Passage certificate before HTTPS can be decrypted.")
                }
            }

            Section("Decrypt") {
                Picker("Decrypt", selection: $decryptAll) {
                    Text("Selected Hosts").tag(false)
                    Text("All Hosts").tag(true)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .onChange(of: decryptAll) {
                    if decryptAll && !model.decryptAll {
                        model.seedDecryptAllDefaults()
                        load()
                        decryptAll = true
                    }
                    saveSSL()
                }
            }

            if decryptAll {
                hostList(excluded, prompt: "*.example.com", text: $newHost, add: addHost) {
                    excluded.remove(atOffsets: $0); saveExcluded()
                } header: { Text("Except") } footer: {
                    SectionFooter {
                        Text("Every HTTPS host is decrypted except these. Apple services are on the list from the start because they reject the certificate. Apps that pin their certificates will stop connecting.")
                    }
                }
            } else {
                hostList(sslHosts, prompt: "api.example.com or *.example.com", text: $newSSLHost, add: addSSLHost) {
                    sslHosts.remove(atOffsets: $0); saveSSL()
                } header: { Text("Decrypted Hosts") } footer: {
                    SectionFooter {
                        Text("Only these hosts are decrypted. Other HTTPS traffic passes through untouched. Add hosts here, or swipe left on a host in Traffic and tap Decrypt.")
                    }
                }
                hostList(excluded, prompt: "*.example.com", text: $newHost, add: addHost) {
                    excluded.remove(atOffsets: $0); saveExcluded()
                } header: { Text("Do Not Decrypt") } footer: {
                    SectionFooter {
                        Text("Traffic to these hosts passes through untouched. “*.example.com” also covers example.com.")
                    }
                }
            }

            Section {
                Toggle("Skip Pinned Hosts Automatically", isOn: $autoPinning)
                    .onChange(of: autoPinning) { saveAutoPinning() }
                if autoPinning {
                    ForEach(pinned, id: \.self) { host in
                        Text(host).font(.mono(.body))
                            .deleteSwipe { if let i = pinned.firstIndex(of: host) { unpin(IndexSet(integer: i)) } }
                    }
                    .onDelete(perform: unpin)
                }
                Toggle("HTTP/2", isOn: $http2)
                    .onChange(of: http2) { saveHTTP2() }
            } header: { Text("Advanced") } footer: {
                SectionFooter {
                    Text((autoPinning
                          ? "When an app rejects the certificate, its host stops being decrypted and is listed above. Swipe it to try again. "
                          : "Hosts stay decrypted even when their app rejects the certificate. ")
                         + "HTTP/2 is used when both the app and the server support it. When it’s off, every decrypted connection uses HTTP/1.1.")
                }
            }

            if model.caExpiryWarning == nil {
                Section {
                    Button("Regenerate Certificate", role: .destructive) { confirmRegenerate = true }
                } footer: { SectionFooter { Text("Creates a new certificate. You must install and trust it again.") } }
            }

            if let error { Section { Text(error).foregroundStyle(.statusError) } }
        }
        .navigationTitle("HTTPS Decryption")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .confirmationDialog("Regenerate the certificate?", isPresented: $confirmRegenerate, titleVisibility: .visible) {
            Button("Regenerate", role: .destructive) {
                Task {
                    do { try await model.regenerateCA() } catch { self.error = error.localizedDescription }
                }
            }
        } message: { Text("The old certificate stops working immediately.") }
    }

    /// A list of host patterns with a field to add one.
    private func hostList(_ hosts: [String], prompt: String, text: Binding<String>, add: @escaping () -> Void,
                          delete: @escaping (IndexSet) -> Void,
                          @ViewBuilder header: () -> some View, @ViewBuilder footer: () -> some View) -> some View {
        Section {
            ForEach(hosts, id: \.self) { host in
                Text(host).font(.mono(.body))
                    .deleteSwipe { if let i = hosts.firstIndex(of: host) { delete(IndexSet(integer: i)) } }
            }
            .onDelete(perform: delete)
            HStack {
                TextField("Host", text: text, prompt: Text(verbatim: prompt))
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .onSubmit(add)
                Button("Add", action: add).disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: { header() } footer: { SectionFooter { footer() } }
    }

    private func load() {
        model.loadCAExpiry()
        guard let store = model.store else { return }
        excluded = (try? store.setting(Settings.excludedHosts)) ?? []
        sslHosts = model.sslProxyingHosts
        decryptAll = model.decryptAll
        pinned = ((try? store.pinnedHosts()) ?? []).sorted()
        autoPinning = (try? store.setting(Settings.autoPinning)) ?? false
        http2 = (try? store.setting(Settings.http2Enabled)) ?? true
    }

    /// A host pattern from what was typed: a pasted URL gives its host.
    static func hostPattern(_ input: String) -> String {
        let text = input.trimmingCharacters(in: .whitespaces).lowercased()
        if text.contains("://"), let host = URLComponents(string: text)?.host { return host }
        return text
    }

    private func addSSLHost() {
        let host = Self.hostPattern(newSSLHost)
        guard !host.isEmpty, !sslHosts.contains(host) else { return }
        sslHosts.append(host)
        newSSLHost = ""
        saveSSL()
    }

    private func saveSSL() {
        guard sslHosts != model.sslProxyingHosts || decryptAll != model.decryptAll else { return }
        model.saveSSLProxying(hosts: sslHosts, decryptAll: decryptAll)
    }

    private func addHost() {
        let host = Self.hostPattern(newHost)
        guard !host.isEmpty, !excluded.contains(host) else { return }
        excluded.append(host)
        newHost = ""
        saveExcluded()
    }

    private func saveExcluded() {
        do {
            try model.store?.setSetting(Settings.excludedHosts, excluded)
            Task { await model.settingsChanged() }
        } catch { self.error = error.localizedDescription }
    }

    private func saveAutoPinning() {
        guard let store = model.store, autoPinning != ((try? store.setting(Settings.autoPinning)) ?? false) else { return }
        do {
            try store.setSetting(Settings.autoPinning, autoPinning)
            Task { await model.settingsChanged() }
        } catch { self.error = error.localizedDescription }
    }

    private func saveHTTP2() {
        guard let store = model.store, http2 != ((try? store.setting(Settings.http2Enabled)) ?? true) else { return }
        do {
            try store.setSetting(Settings.http2Enabled, http2)
            Task { await model.settingsChanged() }
        } catch { self.error = error.localizedDescription }
    }

    private func unpin(_ offsets: IndexSet) {
        for i in offsets { try? model.store?.setPinned(pinned[i], false) }
        pinned.remove(atOffsets: offsets)
        Task { await model.settingsChanged() }
    }
}

/// Trust and expiry of the root CA in one short label; expiry wins because it needs action first.
/// The explicit label style matters: as the value of a `LabeledContent` row, iOS 26 gives a plain `Label` a row-icon
/// layout that makes the row several lines tall.
struct CAStatusLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        status.labelStyle(.titleAndIcon)
    }

    @ViewBuilder private var status: some View {
        switch (model.caExpiry, model.caTrusted) {
        case (.expired?, _): Label("Expired", symbol: .eventBusy).foregroundStyle(.statusError)
        case (.expiresSoon?, _): Label("Expires Soon", symbol: .eventBusy).foregroundStyle(.statusWarning)
        case (_, true?): Label("Trusted", symbol: .verifiedFill).foregroundStyle(.statusSuccess)
        case (_, false?): Label("Not Trusted", symbol: .gppBadFill).foregroundStyle(.statusWarning)
        case (_, nil): Text("Unknown").foregroundStyle(.secondary)
        }
    }
}

extension AppModel {
    /// Shown when the CA is close to or past its end date.
    var caExpiryWarning: String? {
        switch caExpiry {
        case .expiresSoon(let days)?:
            "The Passage certificate expires in \(days) \(days == 1 ? "day" : "days"). Regenerate it, then install and trust the new one."
        case .expired?:
            "The Passage certificate has expired, so HTTPS can’t be decrypted. Regenerate it, then install and trust the new one."
        default: nil
        }
    }
}
