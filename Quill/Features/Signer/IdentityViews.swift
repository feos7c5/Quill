import SwiftData
import SwiftUI

/// Alle Zertifikate (Identitäten) und Profile.
struct IdentitiesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SigningIdentity.addedAt, order: .reverse) private var identities: [SigningIdentity]
    @Query(sort: \ProfileRecord.expirationDate, order: .reverse) private var profiles: [ProfileRecord]

    var body: some View {
        List {
            if let pending = IdentityStore.pendingCSRDate {
                Section {
                    Label("CSR vom \(pending.formatted(date: .abbreviated, time: .shortened)) wartet auf die .cer von Apple.",
                          systemImage: "hourglass")
                } footer: {
                    Text("Die .cer über „Importieren“ hinzufügen.")
                }
            }
            Section("Zertifikate") {
                if identities.isEmpty {
                    Text("Keine").foregroundStyle(.secondary)
                }
                ForEach(identities) { identity in
                    NavigationLink {
                        IdentityDetailView(identity: identity)
                    } label: {
                        IdentityRow(identity: identity, profileCount: IdentityStore.profiles(for: identity, in: profiles).count)
                    }
                }
                .onDelete { offsets in
                    for index in offsets { IdentityStore.delete(identities[index], context: context) }
                }
            }
            Section("Provisioning Profiles") {
                if profiles.isEmpty {
                    Text("Keine").foregroundStyle(.secondary)
                }
                ForEach(profiles) { profile in
                    NavigationLink {
                        ProfileDetailView(profile: profile)
                    } label: {
                        ProfileRow(profile: profile, hasIdentity: identities.contains { profile.certificateHashes.contains($0.certificateHash) })
                    }
                }
                .onDelete { offsets in
                    for index in offsets { IdentityStore.delete(profiles[index], context: context) }
                }
            }
        }
        .navigationTitle("Zertifikate & Profile")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct IdentityRow: View {
    let identity: SigningIdentity
    let profileCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(identity.name).font(.headline).lineLimit(1)
            Text("\(identity.origin.label) · Team \(identity.teamID) · \(profileCount) Profil\(profileCount == 1 ? "" : "e")")
                .font(.caption)
                .foregroundStyle(.secondary)
            ExpiryLabel(date: identity.expirationDate, revoked: identity.revocationStatus == 1)
        }
    }
}

private struct ProfileRow: View {
    let profile: ProfileRecord
    let hasIdentity: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(profile.name).font(.headline).lineLimit(1)
            Text("\(profile.kind.label) · \(profile.bundlePattern)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack {
                ExpiryLabel(date: profile.expirationDate, revoked: false)
                if !hasIdentity {
                    Label("ohne Zertifikat", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            .font(.caption2)
        }
    }
}

struct ExpiryLabel: View {
    let date: Date
    let revoked: Bool

    var body: some View {
        Group {
            if revoked {
                Label("Widerrufen", systemImage: "xmark.seal.fill").foregroundStyle(.red)
            } else if date < .now {
                Label("Abgelaufen", systemImage: "clock.badge.exclamationmark").foregroundStyle(.red)
            } else {
                Label("Gültig bis \(date.formatted(date: .abbreviated, time: .omitted))", systemImage: "clock")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
    }
}

struct IdentityDetailView: View {
    let identity: SigningIdentity

    @Query private var allProfiles: [ProfileRecord]
    @State private var isChecking = false
    @State private var checkMessage: String?

    private var profiles: [ProfileRecord] { IdentityStore.profiles(for: identity, in: allProfiles) }

    var body: some View {
        List {
            Section("Zertifikat") {
                LabeledContent("Name", value: identity.name)
                LabeledContent("Team", value: identity.teamName.isEmpty ? identity.teamID : "\(identity.teamName) (\(identity.teamID))")
                LabeledContent("Herkunft", value: identity.origin.label)
                LabeledContent("Seriennummer") {
                    Text(identity.serial).font(.caption.monospaced()).textSelection(.enabled)
                }
                LabeledContent("Gültig bis", value: identity.expirationDate.formatted(date: .long, time: .omitted))
                LabeledContent("Status") {
                    if isChecking {
                        ProgressView()
                    } else {
                        Text(statusText).foregroundStyle(identity.revocationStatus == 1 ? Color.red : Color.secondary)
                    }
                }
                Button("Widerruf bei Apple prüfen", systemImage: "arrow.clockwise") { check() }
                    .disabled(isChecking || profiles.isEmpty)
                if let checkMessage {
                    Text(checkMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                if profiles.isEmpty {
                    Text("Noch kein passendes Profil importiert.").foregroundStyle(.secondary)
                }
                ForEach(profiles) { profile in
                    NavigationLink {
                        ProfileDetailView(profile: profile)
                    } label: {
                        ProfileRow(profile: profile, hasIdentity: true)
                    }
                }
            } header: {
                Text("Passende Profile")
            } footer: {
                Text("Beim Signieren wählt Quill automatisch das gültige Profil, das zur Bundle-ID und zu diesem iPhone passt; eine exakte App-ID vor einer Wildcard.")
            }
        }
        .navigationTitle("Zertifikat")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var statusText: String {
        switch identity.revocationStatus {
        case 0: return "Gültig"
        case 1: return "Widerrufen"
        case 2: return "Unbekannt"
        default: return "Nicht geprüft"
        }
    }

    private func check() {
        guard let profile = profiles.first else { return }
        isChecking = true
        checkMessage = nil
        Task {
            let result = await IdentityStore.checkRevocation(identity, profile: profile)
            checkMessage = result.message
            isChecking = false
        }
    }
}

struct ProfileDetailView: View {
    let profile: ProfileRecord

    @Environment(DeviceLink.self) private var device
    @State private var parsed: ProvisioningProfile?

    var body: some View {
        List {
            Section("Profil") {
                LabeledContent("Name", value: profile.name)
                LabeledContent("Art", value: profile.kind.label)
                LabeledContent("App-ID", value: profile.applicationIdentifier)
                LabeledContent("Team", value: "\(profile.teamName) (\(profile.teamID))")
                LabeledContent("Gültig bis", value: profile.expirationDate.formatted(date: .long, time: .shortened))
                if let udid = device.udid {
                    LabeledContent("Dieses iPhone", value: profile.includes(device: udid) ? "enthalten" : "nicht enthalten")
                }
            }
            if !profile.devices.isEmpty {
                Section("Registrierte Geräte (\(profile.devices.count))") {
                    ForEach(profile.devices, id: \.self) { udid in
                        Text(udid).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
            if let parsed {
                Section("Entitlements") {
                    ForEach(parsed.entitlements.keys.sorted(), id: \.self) { key in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key).font(.caption.weight(.medium))
                            Text(PlistNode.make(key: key, value: parsed.entitlements[key] as Any).value)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Profil")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { parsed = try? ProvisioningProfile(url: profile.fileURL) }
    }
}

// MARK: - Import

/// Importiert eine Auswahl: Profile und .cer sofort, .p12 mit Passwortabfrage, wenn nötig.
struct IdentityImportView: View {
    let batch: IdentifiedBatch

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var results: [String] = []
    @State private var pending: [ImportBatch.File] = []
    @State private var passwords: [String: String] = [:]
    @State private var errors: [String: String] = [:]
    @State private var started = false

    var body: some View {
        NavigationStack {
            Form {
                if !pending.isEmpty {
                    Section {
                        ForEach(pending, id: \.name) { file in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(file.name).font(.headline)
                                SecureField("Passwort", text: Binding(get: { passwords[file.name] ?? "" },
                                                                      set: { passwords[file.name] = $0 }))
                                if let error = errors[file.name] {
                                    Text(error).font(.caption).foregroundStyle(.red)
                                }
                                Button("Importieren") { importP12(file) }
                            }
                        }
                    } header: {
                        Text("Passwort nötig")
                    } footer: {
                        Text("Das Passwort liegt danach im Schlüsselbund dieses iPhones.")
                    }
                }
                Section("Ergebnis") {
                    if results.isEmpty {
                        Text("Nichts importiert.").foregroundStyle(.secondary)
                    }
                    ForEach(results, id: \.self) { line in
                        Text(line).font(.callout)
                    }
                }
                if !batch.batch.skipped.isEmpty {
                    Section("Übersprungen") {
                        ForEach(batch.batch.skipped, id: \.self) { Text($0).foregroundStyle(.secondary) }
                    }
                }
            }
            .navigationTitle("Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .onAppear(perform: start)
        }
    }

    private func start() {
        guard !started else { return }
        started = true
        for file in batch.batch.profiles {
            do {
                let profile = try IdentityStore.importProfile(file.data, context: context)
                results.append("✓ Profil „\(profile.name)“ (\(profile.bundlePattern))")
            } catch {
                results.append("✗ \(file.name): \(error.localizedDescription)")
            }
        }
        for file in batch.batch.certificates {
            do {
                let identity = try IdentityStore.importCertificate(file.data, context: context)
                results.append("✓ Zertifikat „\(identity.name)“ aus CSR")
            } catch {
                results.append("✗ \(file.name): \(error.localizedDescription)")
            }
        }
        for file in batch.batch.p12s {
            if IdentityStore.needsPassword(file.data) {
                pending.append(file)
            } else {
                passwords[file.name] = ""
                importP12(file)
            }
        }
    }

    private func importP12(_ file: ImportBatch.File) {
        do {
            let identity = try IdentityStore.importP12(file.data, password: passwords[file.name] ?? "", context: context)
            results.append("✓ Zertifikat „\(identity.name)“ (Team \(identity.teamID))")
            pending.removeAll { $0.name == file.name }
            errors[file.name] = nil
        } catch {
            errors[file.name] = error.localizedDescription
        }
    }
}

// MARK: - Export

struct ExportIdentityView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SigningIdentity.addedAt, order: .reverse) private var identities: [SigningIdentity]
    @Query private var allProfiles: [ProfileRecord]

    @State private var selection: UUID?
    @State private var useNewPassword = true
    @State private var newPassword = ""
    @State private var includeProfiles = false
    @State private var exported: URL?
    @State private var errorText: String?
    @State private var authorized = false

    private var identity: SigningIdentity? { identities.first { $0.id == selection } ?? identities.first }

    var body: some View {
        NavigationStack {
            Form {
                Section("Zertifikat") {
                    Picker("Zertifikat", selection: Binding(get: { identity?.id }, set: { selection = $0 })) {
                        ForEach(identities) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                Section {
                    Toggle("Neues Passwort setzen", isOn: $useNewPassword)
                    if useNewPassword {
                        SecureField("Neues Passwort (leer = ohne)", text: $newPassword)
                    }
                    Toggle("Passende Profile mitnehmen (.zip)", isOn: $includeProfiles)
                } footer: {
                    Text("Ohne neues Passwort behält die Datei das Passwort, mit dem sie importiert wurde. Für LiveContainer ein Passwort setzen und dort beim Import eingeben.")
                }
                if let errorText {
                    Section { Label(errorText, systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
                }
                Section {
                    if let exported {
                        ShareLink(item: exported) {
                            Label("\(exported.lastPathComponent) teilen / sichern", systemImage: "square.and.arrow.up")
                        }
                    } else {
                        Button("Exportieren") { Task { await export() } }
                            .disabled(identity == nil)
                    }
                } footer: {
                    Text("Wer diese Datei und ihr Passwort hat, kann in deinem Namen signieren. Nur an sichere Orte speichern.")
                }
            }
            .navigationTitle("Zertifikat exportieren")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .onChange(of: selection) { exported = nil }
            .onChange(of: includeProfiles) { exported = nil }
            .onChange(of: useNewPassword) { exported = nil }
        }
    }

    private func export() async {
        guard let identity else { return }
        errorText = nil
        if !authorized {
            authorized = await DeviceOwner.authenticate(reason: "Privaten Schlüssel exportieren")
            guard authorized else {
                errorText = "Ohne Face ID oder Gerätecode wird nicht exportiert."
                return
            }
        }
        do {
            let profiles = includeProfiles ? IdentityStore.profiles(for: identity, in: allProfiles) : []
            exported = try IdentityStore.export(identity, password: useNewPassword ? .new(newPassword) : .original, profiles: profiles)
        } catch {
            errorText = useNewPassword
                ? "\(error.localizedDescription) Ältere .p12 lassen sich teils nicht umverschlüsseln; dann ohne neues Passwort exportieren."
                : error.localizedDescription
        }
    }
}

// MARK: - CSR

struct CSRView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(DeviceLink.self) private var device

    @State private var name = ""
    @State private var email = ""
    @State private var csrURL: URL?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (z. B. dein Name)", text: $name)
                    TextField("E-Mail (optional)", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Quill erzeugt einen privaten RSA-2048-Schlüssel, der im Schlüsselbund dieses iPhones bleibt, und eine CSR-Datei für Apple.")
                }
                if let errorText {
                    Section { Label(errorText, systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
                }
                if let csrURL {
                    Section("Weiter") {
                        ShareLink(item: csrURL) {
                            Label("CSR sichern (in Dateien)", systemImage: "square.and.arrow.up")
                        }
                        Button("Apple Developer öffnen", systemImage: "safari") {
                            if let udid = device.udid { UIPasteboard.general.string = udid }
                            openURL(URL(string: "https://developer.apple.com/account/resources/certificates/add")!)
                        }
                        Text("Dort „Apple Development“ wählen, die CSR hochladen, die .cer laden und hier über „Importieren“ hinzufügen. Für das Profil das Gerät mit der UDID aus der Zwischenablage registrieren.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        Button("CSR erzeugen") { create() }
                            .disabled(name.trimmed.isEmpty)
                    } footer: {
                        if IdentityStore.pendingCSRDate != nil {
                            Text("Eine frühere CSR wartet noch. Eine neue ersetzt deren Schlüssel; die alte .cer passt dann nicht mehr.")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .navigationTitle("Zertifikatsanfrage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }

    private func create() {
        do {
            csrURL = try IdentityStore.createCSR(commonName: name.trimmed, email: email.trimmed.isEmpty ? nil : email.trimmed)
        } catch {
            errorText = error.localizedDescription
        }
    }
}
