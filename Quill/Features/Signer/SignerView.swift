import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Start-Tab: Status, Signieren, installierte Apps, Account, Gerät, Zertifikate.
struct SignerView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Environment(DeviceLink.self) private var device
    @Environment(AppleAccountService.self) private var account
    @Environment(SigningPipeline.self) private var pipeline

    @Query(sort: \InstalledApp.expirationDate) private var installed: [InstalledApp]
    @Query(sort: \SigningIdentity.addedAt, order: .reverse) private var identities: [SigningIdentity]
    @Query private var profiles: [ProfileRecord]

    @State private var sheet: SignerSheet?
    // Art und Sichtbarkeit getrennt halten: Beim Schließen setzt SwiftUI die Sichtbarkeit zurück,
    // bevor das Ergebnis ankommt. Die Art muss dann noch bekannt sein.
    @State private var importerKind: ImporterKind = .ipa
    @State private var showImporter = false
    @State private var askURL = false
    @State private var urlText = ""
    @State private var confirmReset = false
    @State private var busyText: String?
    @State private var errorText: String?

    var body: some View {
        List {
            statusSection
            signSection
            InstalledAppsSection(apps: installed)
            accountSection
            deviceSection
            identitySection
        }
        .navigationTitle("Quill")
        .refreshable { await device.refresh() }
        .task {
            if device.isPaired, device.state != .ready { await device.refresh() }
            await account.restoreIfPossible()
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .pairing: PairingView()
            case .login: LoginView()
            case .identityImport(let batch): IdentityImportView(batch: batch)
            case .export: ExportIdentityView()
            case .csr: CSRView()
            case .liveContainer: LiveContainerView()
            case .udid: UDIDView()
            }
        }
        .onChange(of: account.wantsLogin) { _, wants in
            guard wants else { return }
            account.wantsLogin = false
            sheet = .login
        }
        .onChange(of: account.state) { _, state in
            // Eine automatische Anmeldung (App-Start, Refresh) kann nach einem Code fragen.
            if case .needsCode = state, sheet == nil { sheet = .login }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: importerKind.types,
                      allowsMultipleSelection: importerKind.multiple) { result in
            switch result {
            case .success(let urls): handleImport(importerKind, urls: urls)
            case .failure(let error): errorText = error.localizedDescription
            }
        }
        .alert("IPA von URL laden", isPresented: $askURL) {
            TextField("https://…/App.ipa", text: $urlText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Laden") { signFromURL() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Die IPA wird geladen, signiert und installiert.")
        }
        .alert("Alle Zertifikate und Profile löschen?", isPresented: $confirmReset) {
            Button("Abbrechen", role: .cancel) {}
            Button("Alles löschen", role: .destructive) { reset() }
        } message: {
            Text("Löscht alle importierten Zertifikate, Profile und einen wartenden CSR-Schlüssel aus Quill. Installierte Apps bleiben, lassen sich damit aber nicht mehr erneuern.")
        }
        .messageAlert(message: $errorText)
    }

    // MARK: - Status

    private var signerName: String? {
        if account.isReady, let team = account.team {
            let who = account.status?.name ?? account.email ?? String(localized: "Apple-ID")
            return "\(who) · \(team.isFree ? String(localized: "7 Tage") : String(localized: "1 Jahr"))"
        }
        return identities.first { !$0.isExpired }?.name
    }

    private var isReady: Bool { signerName != nil && device.udid != nil && device.isReady }

    private var statusSection: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isReady ? "Bereit" : "Einrichtung nötig")
                        .font(.headline)
                    Text(statusDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: isReady ? "checkmark.seal.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(isReady ? .green : .orange)
                    .imageScale(.large)
            }
            if !isReady {
                setupStep(done: signerName != nil,
                          busy: signerName == nil && account.state == .signingIn,
                          title: "Mit Apple-ID anmelden",
                          detail: signerName == nil && account.state == .signingIn
                              ? String(localized: "Anmeldung läuft …")
                              : signerName ?? String(localized: "Oder unten unter „Eigene Zertifikate“ ein Zertifikat importieren.")) {
                    sheet = .login
                }
                // Die Kopplung liefert die UDID mit; den Weg über das Safari-Profil braucht es nur ohne Kopplung.
                setupStep(done: device.isPaired,
                          title: "Gerät koppeln",
                          detail: String(localized: "Einmalig, ohne Computer. Liefert auch die UDID.")) {
                    sheet = .pairing
                }
                if !device.isPaired && device.udid == nil {
                    Button("UDID ohne Kopplung ermitteln", systemImage: "number") { sheet = .udid }
                        .font(.footnote)
                }
                if device.isPaired {
                    setupStep(done: device.isReady,
                              title: "LocalDevVPN verbinden",
                              detail: unreachableReason ?? String(localized: "In LocalDevVPN verbinden, dann hier tippen.")) {
                        Task { await device.refresh() }
                    }
                }
            } else {
                LabeledContent("Signieren mit", value: signerName ?? "")
                if let mode = device.developerMode, !mode {
                    LabeledContent("Entwicklermodus") { Text("Aus").foregroundStyle(.orange) }
                }
            }
        }
    }

    private var unreachableReason: String? {
        if case .unreachable(let reason) = device.state { return reason }
        return nil
    }

    /// Ein Schritt der Einrichtung: erledigt mit Häkchen, offen als antippbare Zeile.
    private func setupStep(done: Bool, busy: Bool = false, title: LocalizedStringKey, detail: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Group {
                    if busy {
                        // Läuft gerade (z. B. automatische Anmeldung beim Start): nicht als „fehlt“ zeigen.
                        ProgressView()
                    } else {
                        Image(systemName: done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(done ? Color.green : Color.secondary)
                            .imageScale(.large)
                    }
                }
                .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(done ? .secondary : .primary)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Spacer(minLength: 0)
                if !done && !busy {
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(done || busy)
    }

    private var statusDetail: String {
        if isReady { return String(localized: "Apps können signiert und installiert werden.") }
        if device.state == .checking { return String(localized: "Verbindung wird geprüft …") }
        return String(localized: "Diese Schritte einmal erledigen:")
    }

    // MARK: - Signieren

    private var signSection: some View {
        Section {
            Button {
                present(.ipa)
            } label: {
                Label("IPA wählen und installieren", systemImage: "plus.app")
            }
            .disabled(isBusy)

            Button {
                urlText = ""
                askURL = true
            } label: {
                Label("Von URL laden", systemImage: "link")
            }
            .disabled(isBusy)

            Button {
                sheet = .liveContainer
            } label: {
                Label("LiveContainer einrichten", systemImage: "square.stack.3d.up")
            }

            if let busyText {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(busyText).font(.subheadline)
                }
            }
            PipelineProgressView()
        } header: {
            Text("Signieren")
        } footer: {
            Text("LiveContainer startet beliebig viele Apps in einer einzigen installierten App.")
        }
    }

    private var isBusy: Bool { busyText != nil || pipeline.isRunning }

    // MARK: - Apple-Account

    private var accountSection: some View {
        Section {
            if account.isSignedIn {
                NavigationLink {
                    AccountDetailView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.status?.name ?? account.email ?? "Apple-ID")
                            Text(account.team.map { "\($0.displayName) · \($0.id)" } ?? "Team wählen")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "person.crop.circle")
                    }
                }
            } else {
                Button {
                    sheet = .login
                } label: {
                    Label(account.state == .signingIn ? "Anmeldung läuft …" : "Mit Apple-ID anmelden", systemImage: "person.crop.circle")
                }
                .disabled(account.state == .signingIn)
            }
        } header: {
            Text("Apple-Account")
        } footer: {
            Text("Quill erstellt Zertifikat und Profil automatisch. Kostenlose Apple-ID: 7 Tage Laufzeit, höchstens drei Apps. Bezahlter Account: ein Jahr.")
        }
    }

    // MARK: - Gerät

    private var deviceSection: some View {
        Section {
            Button {
                sheet = .pairing
            } label: {
                LabeledContent {
                    if device.isPaired { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                } label: {
                    Label("Koppeln ohne Computer", systemImage: "link")
                }
            }
            Button {
                present(.pairingFile)
            } label: {
                Label("Pairing-Datei importieren", systemImage: "square.and.arrow.down")
            }
            Button {
                sheet = .udid
            } label: {
                LabeledContent {
                    Text(device.udid?.maskedUDID ?? "Unbekannt")
                } label: {
                    Label("UDID", systemImage: "number")
                }
            }
            .contextMenu {
                if let udid = device.udid {
                    Button("Kopieren", systemImage: "doc.on.doc") { UIPasteboard.general.string = udid }
                }
            }
        } header: {
            Text("Gerät")
        } footer: {
            Text("Die Kopplung braucht den Entwicklermodus und die App LocalDevVPN. Danach installiert Quill Apps direkt.")
        }
    }

    // MARK: - Zertifikate

    private var identitySection: some View {
        Section {
            NavigationLink {
                IdentitiesView()
            } label: {
                LabeledContent {
                    Text("\(identities.count)")
                } label: {
                    Label("Zertifikate & Profile", systemImage: "checkmark.seal")
                }
            }
            Button {
                present(.identityFiles)
            } label: {
                Label("Importieren", systemImage: "square.and.arrow.down")
            }
            Button {
                sheet = .export
            } label: {
                Label("Zertifikat exportieren", systemImage: "square.and.arrow.up")
            }
            .disabled(identities.isEmpty)
            Button {
                sheet = .csr
            } label: {
                Label("Zertifikatsanfrage (CSR) erzeugen", systemImage: "doc.badge.plus")
            }
            Button {
                openAppleDeveloper()
            } label: {
                Label("Apple Developer öffnen", systemImage: "safari")
            }
            Button(role: .destructive) {
                confirmReset = true
            } label: {
                Label("Zurücksetzen", systemImage: "trash")
            }
            .disabled(identities.isEmpty && profiles.isEmpty && IdentityStore.pendingCSRDate == nil)
        } header: {
            Text("Eigene Zertifikate")
        } footer: {
            Text("Import von .p12, .mobileprovision, .cer oder .zip, etwa von einem UDID-Registrierungsdienst. Eine Apple-Anmeldung ist dafür nicht nötig.")
        }
    }

    // MARK: - Aktionen

    private func present(_ kind: ImporterKind) {
        importerKind = kind
        showImporter = true
    }

    private func handleImport(_ kind: ImporterKind, urls: [URL]) {
        switch kind {
        case .ipa:
            guard let url = urls.first else { return }
            Task { await importAndSign(url) }
        case .pairingFile:
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                try device.importPairingFile(Data(contentsOf: url))
                Task { await device.refresh() }
            } catch {
                errorText = error.localizedDescription
            }
        case .identityFiles:
            do {
                let batch = try IdentityStore.collect(urls)
                guard !batch.isEmpty else {
                    errorText = "Keine .p12, .mobileprovision oder .cer gefunden."
                    return
                }
                sheet = .identityImport(IdentifiedBatch(batch: batch))
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func importAndSign(_ url: URL) async {
        do {
            // Vor dem Kopieren prüfen, damit ein fehlendes Zertifikat sofort gemeldet wird.
            let method = try signingMethod()
            busyText = "Importiere \(url.lastPathComponent) …"
            let app: LibraryApp
            do {
                app = try await AppLibrary.importIPA(from: url, context: context)
            } catch {
                busyText = nil
                throw error
            }
            busyText = nil
            try await pipeline.run(SigningInput(source: app, options: SignOptions.loadDefaults(), method: method), context: context)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func signFromURL() {
        guard let url = URL(string: urlText.trimmed), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
            errorText = "Bitte eine gültige http(s)-Adresse eingeben."
            return
        }
        Task {
            do {
                let method = try signingMethod()
                busyText = "Lade \(url.lastPathComponent) …"
                defer { busyText = nil }
                let (file, response) = try await URLSession.shared.download(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw AppError("Der Server hat die IPA nicht geliefert.")
                }
                let name = url.pathExtension.lowercased() == "ipa" ? url.lastPathComponent : "Download.ipa"
                let ipa = Paths.temporary.appendingPathComponent("\(UUID().uuidString)-\(name)")
                try FileManager.default.moveItem(at: file, to: ipa)
                busyText = "Importiere …"
                let app = try await AppLibrary.importIPA(from: ipa, move: true, context: context)
                busyText = nil
                try await pipeline.run(SigningInput(source: app, options: SignOptions.loadDefaults(), method: method), context: context)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func signingMethod() throws -> SigningMethod {
        guard let method = pipeline.defaultMethod(context: context) else {
            throw AppError("Noch kein Zertifikat vorhanden. Zuerst mit der Apple-ID anmelden oder ein Zertifikat (.p12) mit Profil importieren.")
        }
        return method
    }

    private func reset() {
        do {
            try IdentityStore.reset(context: context)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func openAppleDeveloper() {
        if let udid = device.udid {
            UIPasteboard.general.string = udid
        }
        openURL(URL(string: "https://developer.apple.com/account/resources/certificates/add")!)
    }
}

// MARK: - Hilfstypen

enum SignerSheet: Identifiable {
    case pairing, login, export, csr, liveContainer, udid
    case identityImport(IdentifiedBatch)

    var id: String {
        switch self {
        case .pairing: return "pairing"
        case .login: return "login"
        case .export: return "export"
        case .csr: return "csr"
        case .liveContainer: return "lc"
        case .udid: return "udid"
        case .identityImport(let batch): return "import-\(batch.id)"
        }
    }
}

struct IdentifiedBatch: Identifiable {
    let id = UUID()
    let batch: ImportBatch
}

private enum ImporterKind {
    case ipa, pairingFile, identityFiles

    var types: [UTType] {
        switch self {
        case .ipa: return [UTType(filenameExtension: "ipa") ?? .data, .zip, .data]
        case .pairingFile: return [.propertyList, .xml, .data]
        case .identityFiles: return [.item]
        }
    }

    var multiple: Bool { self == .identityFiles }
}
