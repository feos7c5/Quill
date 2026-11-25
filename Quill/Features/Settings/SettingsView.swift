import SwiftUI

struct SettingsView: View {
    @Environment(\.openURL) private var openURL
    @Environment(WiFiTransferService.self) private var transfer
    @Environment(DeviceLink.self) private var device
    @AppStorage("downloads.autoImport") private var autoImport = true
    @AppStorage(DeviceLink.addressKey) private var deviceAddress = ""
    @AppStorage(AppleAccountService.anisetteKey) private var anisetteURL = ""

    /// Sprache, in der Quill gerade angezeigt wird, in dieser Sprache benannt.
    private var currentLanguage: String {
        let code = Bundle.main.preferredLocalizations.first ?? "de"
        let locale = Locale(identifier: code)
        return locale.localizedString(forLanguageCode: code)?.capitalized(with: locale) ?? code
    }

    @State private var defaults = SignOptions.loadDefaults()
    @State private var cacheSize: Int64 = 0
    @State private var errorText: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Sprache", value: currentLanguage)
                Button("Sprache ändern") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            } header: {
                Text("Sprache")
            } footer: {
                Text("Quill folgt der Sprache des iPhones. Eine eigene Sprache nur für Quill lässt sich in den iOS-Einstellungen unter Quill → Sprache wählen.")
            }

            Section {
                LabeledContent("Adresse") {
                    TextField(DeviceLink.defaultAddress, text: $deviceAddress)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                }
                NavigationLink("Protokoll des Kerns") { LogFileView(url: Paths.core.appendingPathComponent("core.log"), title: "Protokoll") }
                NavigationLink("Protokoll der UDID-Erkennung") { LogFileView(url: UDIDProfileService.logURL, title: "UDID-Erkennung") }
                NavigationLink("Protokoll der Kopplung") { LogFileView(url: PairingLog.url, title: "Kopplung") }
                if device.isPaired {
                    Button("Kopplung entfernen", role: .destructive) { device.unpair() }
                }
            } header: {
                Text("Gerätekanal")
            } footer: {
                Text("Über LocalDevVPN erreicht Quill die Gerätedienste dieses iPhones unter 10.7.0.1:49152. Nur ändern, wenn ein anderes VPN eine andere Adresse nutzt.")
            }

            Section {
                TextField(AppleAccountService.defaultAnisette, text: $anisetteURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            } header: {
                Text("Anisette-Server")
            } footer: {
                Text("Liefert bei der Apple-Anmeldung Gerätekenndaten, die eine App nicht selbst erzeugen kann (Protokoll „v3“, wie iloader und SideStore). Der Server sieht deine IP-Adresse, nicht dein Passwort. Ein eigener Server ist möglich.")
            }

            Section {
                NavigationLink {
                    InstallSettingsView()
                } label: {
                    Label("Installation ohne Kopplung", systemImage: "arrow.down.app")
                }
            } footer: {
                Text("Nur nötig, wenn Quill nicht gekoppelt ist: Installation über itms-services mit eigenem HTTPS-Zertifikat.")
            }

            Section {
                Toggle("Dateiübertragung aktiv", isOn: Binding(get: { transfer.isRunning }, set: setTransfer))
                if transfer.isRunning {
                    if let address = transfer.address {
                        LabeledContent("Adresse") {
                            Text(address).textSelection(.enabled)
                        }
                    } else {
                        Text("Kein WLAN verbunden.").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("WLAN-Übertragung")
            } footer: {
                Text("Öffnet den Ordner „Dateien“ im Browser eines Geräts im selben WLAN. Die Verbindung ist unverschlüsselt und ohne Passwort – nur in vertrauenswürdigen Netzen einschalten und die App geöffnet lassen.")
            }

            Section {
                Toggle("App-Erweiterungen entfernen", isOn: $defaults.removePlugIns)
                Toggle("Watch-App entfernen", isOn: $defaults.removeWatchApp)
                Toggle("Gerätebeschränkung entfernen", isOn: $defaults.removeSupportedDevices)
                Toggle("URL-Schemata entfernen", isOn: $defaults.removeURLSchemes)
                Toggle("Dateifreigabe aktivieren", isOn: $defaults.enableFileSharing)
                Toggle("Nach dem Signieren installieren", isOn: $defaults.installAfterSigning)
                Toggle("Apple-Account: mehr Arbeitsspeicher (+RAM)", isOn: $defaults.increasedMemoryLimit)
                Toggle("Apple-Account: Erweiterungen mit eigener App-ID", isOn: $defaults.registerExtensions)
            } header: {
                Text("Standard beim Signieren")
            } footer: {
                Text("Gilt auch für „IPA wählen und installieren“ und „Von URL laden“. Ohne eigene App-IDs teilen Erweiterungen das Profil der Haupt-App; das spart App-IDs, manche Erweiterungen laufen dann aber nicht.")
            }

            Section("Downloads") {
                Toggle("Geladene IPAs in Apps importieren", isOn: $autoImport)
            }

            Section("Speicher") {
                LabeledContent("Temporäre Dateien", value: cacheSize.fileSizeText)
                Button("Temporäre Dateien löschen", systemImage: "trash", role: .destructive) { clearCache() }
            }

            Section("Über") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
                NavigationLink("Lizenzen") { LicensesView() }
            }
        }
        .navigationTitle("Einstellungen")
        .onChange(of: defaults) { _, value in value.saveAsDefaults() }
        .onAppear { cacheSize = Paths.folderSize(Paths.temporary) }
        .alert("Fehler", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    private func setTransfer(_ enabled: Bool) {
        if enabled {
            do {
                try transfer.start()
            } catch {
                errorText = error.localizedDescription
            }
        } else {
            transfer.stop()
        }
    }

    private func clearCache() {
        try? FileManager.default.removeItem(at: Paths.temporary)
        cacheSize = Paths.folderSize(Paths.temporary)
    }
}

struct InstallSettingsView: View {
    @AppStorage(InstallSettings.modeKey) private var modeRaw = InstallMode.localTLS.rawValue
    @AppStorage(InstallSettings.hostKey) private var host = ""
    @AppStorage(InstallSettings.templateKey) private var template = ""

    @State private var hasIdentity = InstallSettings.hasTLSIdentity
    @State private var showImporter = false
    @State private var pendingP12: Data?
    @State private var password = ""
    @State private var askPassword = false
    @State private var errorText: String?

    var body: some View {
        Form {
            Section {
                Picker("Verfahren", selection: $modeRaw) {
                    ForEach(InstallMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
            } footer: {
                Text("iOS installiert Apps nur über ein Manifest, das per HTTPS mit einem vertrauenswürdigen Zertifikat ausgeliefert wird. Ohne Einrichtung lässt sich eine signierte IPA jederzeit über „Teilen“ exportieren, etwa per AirDrop an den Mac.")
            }

            if modeRaw == InstallMode.localTLS.rawValue {
                Section {
                    LabeledContent("Hostname") {
                        TextField("local.example.dev", text: $host)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                    LabeledContent("TLS-Zertifikat", value: hasIdentity ? "vorhanden" : "fehlt")
                    Button("TLS-Zertifikat (.p12) wählen", systemImage: "folder") { showImporter = true }
                    if hasIdentity {
                        Button("TLS-Zertifikat entfernen", role: .destructive) { removeIdentity() }
                    }
                } header: {
                    Text("Lokaler HTTPS-Server")
                } footer: {
                    Text("Benötigt eine eigene Domain, deren DNS-Eintrag auf 127.0.0.1 zeigt, und dafür ein öffentlich gültiges Zertifikat (z. B. Let's Encrypt per DNS-Challenge) als .p12. Manifest und IPA verlassen das Gerät nicht.")
                }
            } else {
                Section {
                    TextField("https://…?url={ipa}", text: $template, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("Adresse des Manifest-Dienstes")
                } footer: {
                    Text("Ein eigener HTTPS-Endpunkt, der ein Manifest erzeugt. Platzhalter: {ipa} (lokale Adresse der IPA), {bundleid}, {version}, {name}. Die IPA selbst lädt iOS vom Gerät; der Dienst erfährt nur die Metadaten.")
                }
            }
        }
        .navigationTitle("Installation")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            pendingP12 = try? Data(contentsOf: url)
            password = ""
            askPassword = pendingP12 != nil
        }
        .alert("Passwort der .p12-Datei", isPresented: $askPassword) {
            SecureField("Passwort", text: $password)
            Button("OK") { storeIdentity() }
            Button("Abbrechen", role: .cancel) { pendingP12 = nil }
        }
        .alert("Fehler", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    private func storeIdentity() {
        guard let data = pendingP12 else { return }
        pendingP12 = nil
        do {
            _ = try PKCS12.identity(p12: data, password: password)
            try data.write(to: Paths.tlsIdentity, options: .completeFileProtectionUntilFirstUserAuthentication)
            Keychain.set(password, for: InstallSettings.tlsPasswordKey)
            hasIdentity = true
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func removeIdentity() {
        try? FileManager.default.removeItem(at: Paths.tlsIdentity)
        Keychain.delete(InstallSettings.tlsPasswordKey)
        hasIdentity = false
    }
}

/// Zeigt eine Protokolldatei (Kern, UDID-Erkennung) zum Lesen und Teilen.
struct LogFileView: View {
    let url: URL
    let title: LocalizedStringKey
    @State private var text = ""

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? String(localized: "Leer.") : text)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ShareLink(item: text)
        }
        .onAppear {
            text = (try? String(contentsOf: url, encoding: .utf8)).map { String($0.suffix(60_000)) } ?? ""
        }
    }
}

struct LicensesView: View {
    var body: some View {
        List {
            Section("idevice") {
                Text("Kopplung, Tunnel und Gerätedienste. © Jackson Coxson, MIT-Lizenz. github.com/jkcoxson/idevice")
            }
            Section("isideload") {
                Text("Apple-Anmeldung, Entwicklerdienste, Signieren mit Account-Zertifikat. © nab138, MIT-Lizenz. github.com/nab138/isideload")
            }
            Section("Rust-Abhängigkeiten") {
                Text("tokio, rustls, ring, reqwest, serde, rsa, rcgen, x509-cert, p12-keystore u. a. unter MIT- bzw. Apache-2.0-Lizenz. Vollständige Liste: QuillCore/Cargo.lock.")
            }
            Section("Kopplung ab iOS 27") {
                Text("Ablauf als „pairable host“ nach dem Vorbild von PhonePair (MIT) und StikDebug.")
            }
            Section("zsign") {
                Text("Signier-Engine. © zhlynn, MIT-Lizenz. Swift-Paket: khcrysalis/Zsign-Package.")
            }
            Section("OpenSSL") {
                Text("Kryptografie für zsign. Apache-Lizenz 2.0. Swift-Paket: krzyzanowskim/OpenSSL.")
            }
            Section("ZIPFoundation") {
                Text("ZIP-Archive lesen und schreiben. © Thomas Zoechling, MIT-Lizenz.")
            }
        }
        .font(.footnote)
        .navigationTitle("Lizenzen")
        .navigationBarTitleDisplayMode(.inline)
    }
}
