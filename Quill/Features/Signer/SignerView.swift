import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Start-Tab: Status, Signieren & Installieren, installierte Apps, Apple-Account, Zertifikat.
struct SignerView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Environment(DeviceLink.self) private var device
    @Environment(AppleAccountService.self) private var account
    @Environment(SigningPipeline.self) private var pipeline
    @Environment(RefreshService.self) private var refresher

    @Query(sort: \InstalledApp.expirationDate) private var installed: [InstalledApp]
    @Query(sort: \SigningIdentity.addedAt, order: .reverse) private var identities: [SigningIdentity]
    @Query private var profiles: [ProfileRecord]

    @State private var sheet: SignerSheet?
    @State private var importer: ImporterKind?
    @State private var askURL = false
    @State private var urlText = ""
    @State private var confirmReset = false
    @State private var errorText: String?
    @State private var notice: String?

    var body: some View {
        List {
            statusSection
            signSection
            InstalledAppsSection(apps: installed)
            Section {
                NavigationLink {
                    AutomationGuideView()
                } label: {
                    Label("Automatisch erneuern (Kurzbefehle)", systemImage: "clock.arrow.2.circlepath")
                }
            }
            accountSection
            identitySection
        }
        .navigationTitle("Signer")
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
        .onChange(of: account.state) { _, state in
            // Eine automatische Anmeldung (App-Start, Refresh) kann nach einem Code fragen.
            if case .needsCode = state, sheet == nil { sheet = .login }
        }
        .fileImporter(isPresented: Binding(get: { importer != nil }, set: { if !$0 { importer = nil } }),
                      allowedContentTypes: importer?.types ?? [.item],
                      allowsMultipleSelection: importer?.multiple ?? false) { result in
            let kind = importer
            importer = nil
            guard case .success(let urls) = result, let kind else { return }
            handleImport(kind, urls: urls)
        }
        .alert("IPA-Adresse", isPresented: $askURL) {
            TextField("https://…/App.ipa", text: $urlText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Laden & signieren") { signFromURL() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Die IPA wird geladen, signiert und installiert.")
        }
        .confirmationDialog("Alle Zertifikate und Profile löschen?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Alles löschen", role: .destructive) { reset() }
        } message: {
            Text("Löscht alle importierten .p12, Profile und einen wartenden CSR-Schlüssel aus Quill. Installierte Apps bleiben, lassen sich mit diesen Zertifikaten aber nicht mehr erneuern.")
        }
        .alert("Fehler", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
        .alert("Hinweis", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            StatusLine()
            HStack {
                Text("UDID: \(device.udid?.maskedUDID ?? "unbekannt")")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Detect") {
                    if device.isPaired {
                        Task { await device.refresh() }
                    } else {
                        sheet = .udid
                    }
                }
                .buttonStyle(.bordered)
                .disabled(device.state == .checking)
                Button("Copy UDID") {
                    UIPasteboard.general.string = device.udid
                    notice = "UDID kopiert."
                }
                .buttonStyle(.bordered)
                .disabled(device.udid == nil)
            }
            if case .unreachable(let reason) = device.state {
                Label(reason, systemImage: "network.slash")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } footer: {
            Label("Schlüssel und Zugangsdaten bleiben auf diesem iPhone. Ausnahme: Bei der Anmeldung spricht Quill mit Apple und mit dem eingestellten Anisette-Server.",
                  systemImage: "lock.fill")
        }
    }

    // MARK: - 1. Signieren

    private var signSection: some View {
        Section("1. Signieren & Installieren") {
            Button {
                importer = .ipa
            } label: {
                Label("Pick & Sign .ipa aus Dateien", systemImage: "shippingbox.fill")
                    .frame(maxWidth: .infinity)
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(pipeline.isRunning)

            Button {
                urlText = ""
                askURL = true
            } label: {
                Label("Sign & Install von URL", systemImage: "globe").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(pipeline.isRunning)

            Button {
                sheet = .liveContainer
            } label: {
                Label("LiveContainer (unbegrenzt Apps, 3-App-Grenze umgehen)", systemImage: "square.stack.3d.up.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.purple)

            if pipeline.isRunning || !pipeline.log.isEmpty {
                PipelineProgressView()
            }
        }
    }

    // MARK: - 2. Apple-Account

    private var accountSection: some View {
        Section {
            if account.isSignedIn {
                NavigationLink {
                    AccountDetailView()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.status?.name ?? account.email ?? "Apple-ID").font(.headline)
                        Text(account.team.map { "\($0.displayName) · \($0.id)" } ?? "Bitte Team wählen")
                            .font(.caption)
                            .foregroundStyle(account.team == nil ? .orange : .secondary)
                    }
                }
            } else {
                Button {
                    sheet = .login
                } label: {
                    Label(account.state == .signingIn ? "Anmeldung läuft …" : "Mit Apple-ID anmelden (Zertifikat & Profil automatisch)",
                          systemImage: "key.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
            }
            HStack {
                Button {
                    sheet = .pairing
                } label: {
                    Label("Wireless Pair (ohne PC)", systemImage: "link").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button {
                    importer = .pairingFile
                } label: {
                    Label("Import Config (.plist)", systemImage: "folder").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        } header: {
            Text("2. Apple-Account (Zertifikat & Profil automatisch)")
        } footer: {
            Text("Bezahlter Account (99 $/Jahr): Apps laufen ein Jahr; ohne Kopplung genügt die UDID („Detect“) und die einmal eingerichtete Installation über itms-services. Kostenlose Apple-ID: 7 Tage, höchstens drei Apps gleichzeitig; einmal „Wireless Pair“ tippen.")
        }
    }

    // MARK: - 3. Zertifikat

    private var identitySection: some View {
        Section {
            HStack {
                Button {
                    importer = .identityFiles
                } label: {
                    Label("Import .p12 / .mobileprovision / .zip", systemImage: "folder").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.green)
            }
            HStack {
                Button {
                    sheet = .export
                } label: {
                    Label("Export .p12", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(identities.isEmpty)
                Button("Reset", role: .destructive) { confirmReset = true }
                    .buttonStyle(.bordered)
                    .disabled(identities.isEmpty && profiles.isEmpty && IdentityStore.pendingCSRDate == nil)
            }
            HStack {
                Button("(1) Generate CSR") { sheet = .csr }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                Button("(2) Open Apple Dev") { openAppleDeveloper() }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
            }
            NavigationLink {
                IdentitiesView()
            } label: {
                LabeledContent("Zertifikate & Profile", value: "\(identities.count) · \(profiles.count)")
            }
        } header: {
            Text("3. Zertifikat (.p12 / Profile / CSR)")
        } footer: {
            Text("Zertifikat von einem UDID-Registrierungsdienst oder aus Apple Developer? .p12 und Profil (auch als .zip) importieren – ohne Apple-Anmeldung. Oder CSR erzeugen, auf developer.apple.com hochladen und die .cer hier importieren; die UDID liegt dabei in der Zwischenablage.")
        }
    }

    // MARK: - Aktionen

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
            let app = try await AppLibrary.importIPA(from: url, context: context)
            try await sign(app)
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
                let (file, response) = try await URLSession.shared.download(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw AppError("Der Server hat die IPA nicht geliefert.")
                }
                let name = url.pathExtension.lowercased() == "ipa" ? url.lastPathComponent : "Download.ipa"
                let ipa = Paths.temporary.appendingPathComponent("\(UUID().uuidString)-\(name)")
                try FileManager.default.moveItem(at: file, to: ipa)
                let app = try await AppLibrary.importIPA(from: ipa, move: true, context: context)
                try await sign(app)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func sign(_ app: LibraryApp) async throws {
        guard let method = pipeline.defaultMethod(context: context) else {
            throw AppError("Kein Zertifikat vorhanden. Mit der Apple-ID anmelden oder ein .p12 mit Profil importieren.")
        }
        try await pipeline.run(SigningInput(source: app, options: SignOptions.loadDefaults(), method: method), context: context)
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
        case .ipa: return [UTType("com.apple.itunes.ipa") ?? .data, .data]
        case .pairingFile: return [.propertyList, .data]
        case .identityFiles: return [.item]
        }
    }

    var multiple: Bool { self == .identityFiles }
}

/// Zusammenfassung wie im Screenshot: Signer bereit (Name • Team • Laufzeit • +RAM) • Gekoppelt • Entwicklermodus.
struct StatusLine: View {
    @Environment(DeviceLink.self) private var device
    @Environment(AppleAccountService.self) private var account
    @Query(sort: \SigningIdentity.addedAt, order: .reverse) private var identities: [SigningIdentity]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 14, height: 14)
                .padding(.top, 3)
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(color)
        }
        .accessibilityElement(children: .combine)
    }

    private var signerReady: Bool { account.isReady || identities.contains { !$0.isExpired } }

    private var color: Color {
        if signerReady && device.isReady { return .green }
        if signerReady || device.isPaired { return .orange }
        return .red
    }

    private var text: String {
        var parts: [String] = []
        if account.isReady, let team = account.team {
            let who = account.status?.name ?? account.email ?? "Apple-ID"
            let duration = team.isFree ? "7d Personal" : "1y"
            let ram = SignOptions.loadDefaults().increasedMemoryLimit ? " • +RAM" : ""
            parts.append("Signer bereit (\(who) • Team \(team.id) • \(duration)\(ram))")
        } else if let identity = identities.first(where: { !$0.isExpired }) {
            parts.append("Signer bereit (\(identity.name) • Team \(identity.teamID))")
        } else {
            parts.append("Kein Zertifikat")
        }
        switch device.state {
        case .ready: parts.append("Gekoppelt ✓")
        case .checking: parts.append("Prüfe …")
        case .unpaired: parts.append("Nicht gekoppelt")
        case .unreachable: parts.append("Gekoppelt, nicht erreichbar")
        }
        if let mode = device.developerMode {
            parts.append(mode ? "Dev Mode ✓" : "Dev Mode aus")
        }
        return parts.joined(separator: " • ")
    }
}

/// Fortschritt und Protokoll des laufenden oder letzten Signiervorgangs.
struct PipelineProgressView: View {
    @Environment(SigningPipeline.self) private var pipeline

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if pipeline.isRunning {
                ProgressView(value: pipeline.progress) {
                    Text(pipeline.status).font(.footnote)
                }
            } else if pipeline.failed {
                Label(pipeline.status, systemImage: "xmark.octagon").font(.footnote).foregroundStyle(.red)
            } else {
                Label(pipeline.status, systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.secondary)
            }
            DisclosureGroup("Protokoll") {
                Text(pipeline.log.joined(separator: "\n"))
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.footnote)
        }
    }
}
