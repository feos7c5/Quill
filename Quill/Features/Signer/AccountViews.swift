import SwiftUI

/// Anmeldung mit Apple-ID inklusive zweitem Faktor.
struct LoginView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppleAccountService.self) private var account

    @State private var email = UserDefaults.standard.string(forKey: AppleAccountService.emailKey) ?? ""
    @State private var password = ""
    @State private var remember = true
    @State private var code = ""

    var body: some View {
        NavigationStack {
            Form {
                switch account.state {
                case .needsCode(let request):
                    twoFactorSection(request)
                case .signedIn:
                    signedInSection
                default:
                    credentialsSection
                }
            }
            .navigationTitle("Apple-ID")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(account.state == .signedIn ? "Fertig" : "Abbrechen") {
                        if case .needsCode = account.state { account.abortSignIn() }
                        dismiss()
                    }
                }
            }
            .interactiveDismissDisabled(account.state == .signingIn)
        }
    }

    private var credentialsSection: some View {
        Group {
            Section {
                TextField("Apple-ID (E-Mail)", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Passwort", text: $password)
                    .textContentType(.password)
                Toggle("Passwort zum Erneuern merken", isOn: $remember)
            } footer: {
                Text("Mit „merken“ liegt das Passwort im Schlüsselbund dieses iPhones, damit Quill Apps ohne erneute Eingabe erneuern kann. Am besten eine eigene Apple-ID nur für die Entwicklung verwenden.")
            }

            if let error = account.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task { await account.signIn(email: email.trimmed, password: password, remember: remember) }
                } label: {
                    if account.state == .signingIn {
                        HStack { ProgressView(); Text("Anmelden …") }
                    } else {
                        Text("Anmelden").frame(maxWidth: .infinity)
                    }
                }
                .disabled(email.trimmed.isEmpty || password.isEmpty || account.state == .signingIn)
            } footer: {
                Text("Quill spricht direkt mit Apple. Zusätzlich holt es Gerätekenndaten („Anisette“) vom Server aus den Einstellungen (Standard: ani.iloader.app). Dieser Server sieht deine IP-Adresse, nicht dein Passwort.")
            }
        }
    }

    private func twoFactorSection(_ request: AppleAccountService.TwoFactorRequest) -> some View {
        Group {
            Section {
                TextField("Bestätigungscode", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.title2.monospaced())
                Button("Bestätigen") {
                    account.submitCode(code.trimmed)
                    code = ""
                }
                .disabled(code.trimmed.count < 6)
            } header: {
                Text("Zwei-Faktor-Authentifizierung")
            } footer: {
                if let error = request.lastError {
                    Text(error).foregroundStyle(.red)
                } else if request.sms, let number = request.numbers.first(where: { $0.id == request.selectedNumberID }) {
                    Text("Code wurde per SMS an \(number.number) gesendet.")
                } else {
                    Text("Code wurde an deine Apple-Geräte gesendet.")
                }
            }

            Section("Anderer Weg") {
                if request.sms || request.unknown {
                    Button("An meine Geräte senden") { account.sendToDevices() }
                }
                ForEach(request.numbers.filter { $0.id != request.selectedNumberID }) { number in
                    Button("SMS an \(number.number)") { account.sendSMS(to: number.id) }
                }
                if !request.unknown {
                    Button("Code erneut senden") { account.resendCode() }
                }
            }
        }
    }

    private var signedInSection: some View {
        Group {
            Section {
                Label("Angemeldet als \(account.status?.name ?? account.email ?? "")", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }
            TeamPicker()
        }
    }
}

/// Teamauswahl, falls der Account mehrere Teams hat.
struct TeamPicker: View {
    @Environment(AppleAccountService.self) private var account

    var body: some View {
        Section {
            if account.teams.isEmpty {
                Text("Keine Teams gefunden.").foregroundStyle(.secondary)
            }
            ForEach(account.teams) { team in
                Button {
                    Task { await account.select(team: team) }
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(team.displayName)
                            Text("\(team.id)\(team.type.map { " · \($0)" } ?? "")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if account.team?.id == team.id {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
        } header: {
            Text("Team")
        } footer: {
            if account.team == nil {
                Text("Bitte ein Team wählen, mit dem signiert wird.")
            }
        }
    }
}

/// Account-Übersicht: Team, App-ID-Kontingent, Zertifikate bei Apple, Abmelden.
struct AccountDetailView: View {
    @Environment(AppleAccountService.self) private var account

    @State private var quota: AppIDQuota?
    @State private var certificates: [AppleCertificate] = []
    @State private var isLoading = false
    @State private var revoking: AppleCertificate?
    @State private var confirmRevoke = false
    @State private var confirmSignOut = false
    @State private var confirmSwitch = false
    @State private var deleting: AppIDQuota.Entry?
    @Environment(\.dismiss) private var dismiss
    @State private var errorText: String?

    var body: some View {
        List {
            Section {
                LabeledContent("Apple-ID", value: account.email ?? "–")
                if let name = account.status?.name {
                    LabeledContent("Name", value: name)
                }
            }

            TeamPicker()

            Section {
                if let quota {
                    if let available = quota.available, let max = quota.max {
                        LabeledContent("Freie App-IDs", value: "\(available) von \(max)")
                    }
                    ForEach(quota.appIds) { entry in
                        let isThisApp = entry.identifier == Bundle.main.bundleIdentifier
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                Text(entry.identifier).font(.caption).foregroundStyle(.secondary)
                                if let expires = entry.expires {
                                    Text("läuft ab: \(Date(timeIntervalSince1970: expires).formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            if isThisApp {
                                Text("Diese App").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            // Die App-ID, unter der Quill selbst läuft, nicht anbieten.
                            if !isThisApp && entry.appIdId != nil {
                                Button("Löschen", systemImage: "trash") { deleting = entry }
                                    .tint(.red)
                            }
                        }
                    }
                } else if isLoading {
                    ProgressView()
                }
            } header: {
                Text("App-IDs")
            } footer: {
                Text("Kostenlose Accounts bekommen nur wenige neue App-IDs pro Woche. Jede App und jede ihrer Erweiterungen braucht eine. Apple zählt jede neu angelegte App-ID sieben Tage lang, auch nach dem Löschen. Die freie Anzahl steigt deshalb erst nach einer Woche wieder.")
            }

            Section {
                ForEach(certificates) { certificate in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(certificate.machineName ?? certificate.name ?? "Zertifikat")
                            Text(certificate.serial ?? "").font(.caption2.monospaced()).foregroundStyle(.secondary)
                            if let expires = certificate.expires {
                                Text("gültig bis \(Date(timeIntervalSince1970: expires).formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        if certificate.isQuill {
                            Text("Quill").font(.caption).foregroundStyle(.tint)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Widerrufen", systemImage: "xmark.seal") { revoking = certificate; confirmRevoke = true }
                            .tint(.red)
                    }
                }
            } header: {
                Text("Entwicklungszertifikate bei Apple")
            } footer: {
                Text("Apple erlaubt nur wenige gleichzeitig. Ein Widerruf macht alle damit signierten Apps sofort unbrauchbar, auch auf anderen Geräten und in AltStore/SideStore.")
            }

            Section {
                Button("Apple-Account wechseln", systemImage: "person.2") { confirmSwitch = true }
                Button("Abmelden", systemImage: "rectangle.portrait.and.arrow.right") {
                    Task { await account.signOut(forget: false) }
                }
                Button("Abmelden und alles vergessen", systemImage: "trash", role: .destructive) { confirmSignOut = true }
            }
        }
        .navigationTitle("Apple-Account")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: account.team?.id) { await load() }
        .refreshable { await load() }
        .confirmationDialog("Zertifikat widerrufen?", isPresented: $confirmRevoke,
                            titleVisibility: .visible) {
            Button("Widerrufen", role: .destructive) {
                if let serial = revoking?.serial { revoke(serial) }
            }
        } message: {
            Text("Alle mit diesem Zertifikat signierten Apps starten danach nicht mehr.")
        }
        .confirmationDialog("App-ID löschen?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { entry in
            Button("Löschen", role: .destructive) { delete(entry) }
                .tint(.red)
        } message: { entry in
            Text("„\(entry.name)“ wird bei Apple gelöscht. Apps, die damit signiert sind, lassen sich danach nicht mehr erneuern.")
        }
        .confirmationDialog("Apple-Account wechseln?", isPresented: $confirmSwitch, titleVisibility: .visible) {
            Button("Abmelden und neu anmelden") {
                Task {
                    await account.signOut(forget: true)
                    dismiss()
                    account.wantsLogin = true
                }
            }
        } message: {
            Text("Quill meldet diesen Account ab und vergisst Passwort und Zertifikat. Danach meldest du dich mit dem anderen Account an. Apps, die mit diesem Account signiert sind, lassen sich dann nicht mehr erneuern.")
        }
        .confirmationDialog("Alles vergessen?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Abmelden und vergessen", role: .destructive) { Task { await account.signOut(forget: true) } }
        } message: {
            Text("Löscht gespeichertes Passwort, den privaten Schlüssel des Account-Zertifikats und den Anisette-Zustand. Beim nächsten Anmelden legt Quill ein neues Zertifikat an; Apps mit dem alten lassen sich dann nicht mehr erneuern.")
        }
        .alert("Fehler", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    private func delete(_ entry: AppIDQuota.Entry) {
        guard let appIdId = entry.appIdId else { return }
        Task {
            do {
                try await account.deleteAppID(appIdId)
                await load()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func load() async {
        guard account.isReady else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            quota = try await account.appIDQuota()
            certificates = try await account.certificates()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func revoke(_ serial: String) {
        Task {
            do {
                try await account.revoke(serial: serial)
                await load()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}
