import SwiftUI
import SwiftData
import PhotosUI

/// Signier-Dialog: Weg wählen (Apple-Account oder Zertifikat), Optionen setzen, signieren, installieren.
struct SignView: View {
    let app: LibraryApp

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppleAccountService.self) private var account
    @Environment(SigningPipeline.self) private var pipeline
    @Environment(DeviceLink.self) private var device
    @Query(sort: \SigningIdentity.addedAt, order: .reverse) private var identities: [SigningIdentity]
    @Query private var profiles: [ProfileRecord]

    /// nil = Apple-Account, sonst die gewählte Identität.
    @State private var identityID: UUID?
    @State private var useAccount = true
    @State private var options = SignOptions.loadDefaults()
    @State private var libraries: [URL] = []
    @State private var entitlementsURL: URL?
    @State private var iconItem: PhotosPickerItem?
    @State private var iconData: Data?
    @State private var picker: PickerKind?

    @State private var errorText: String?
    @State private var signedApp: LibraryApp?
    @State private var installedApp: InstalledApp?

    private enum PickerKind: Identifiable {
        case libraries, entitlements
        var id: Self { self }
    }

    private var identity: SigningIdentity? {
        identities.first { $0.id == identityID } ?? identities.first { !$0.isExpired } ?? identities.first
    }

    private var method: SigningMethod? {
        if useAccount && account.isReady { return .account }
        return identity.map { .identity($0, profile: nil) }
    }

    private var isSigning: Bool { pipeline.isRunning }

    var body: some View {
        NavigationStack {
            Form {
                if isSigning || signedApp != nil || errorText != nil {
                    progressSection
                }
                if signedApp == nil {
                    methodSection
                    identitySection
                    modificationSection
                    librarySection
                    advancedSection
                }
            }
            .navigationTitle("Signieren")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(signedApp == nil ? "Abbrechen" : "Fertig") { dismiss() }
                        .disabled(isSigning)
                }
                if signedApp == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Signieren") { startSigning() }
                            .disabled(method == nil || isSigning)
                    }
                }
            }
            .interactiveDismissDisabled(isSigning)
            .fileImporter(isPresented: Binding(get: { picker != nil }, set: { if !$0 { picker = nil } }),
                          allowedContentTypes: [.item],
                          allowsMultipleSelection: picker == .libraries) { result in
                guard case .success(let urls) = result else { return }
                if picker == .entitlements {
                    entitlementsURL = urls.first
                } else {
                    libraries.append(contentsOf: urls.filter { ["dylib", "framework"].contains($0.pathExtension.lowercased()) })
                }
                picker = nil
            }
            .onChange(of: iconItem) { _, item in
                Task { iconData = try? await item?.loadTransferable(type: Data.self) }
            }
        }
    }

    // MARK: - Abschnitte

    private var progressSection: some View {
        Section {
            if isSigning || !pipeline.log.isEmpty {
                PipelineProgressView()
            }
            if let errorText {
                Label(errorText, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }
            if let signedApp {
                if let installedApp {
                    Label("„\(installedApp.name)“ ist installiert, gültig bis \(installedApp.expirationDate.formatted(date: .abbreviated, time: .shortened)).",
                          systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    Label("„\(signedApp.name)“ wurde signiert.", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                }
                ShareLink(item: signedApp.ipaURL, preview: SharePreview(signedApp.exportFileName)) {
                    Label("IPA teilen", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    private var methodSection: some View {
        Section {
            if account.isReady {
                Picker("Signieren mit", selection: $useAccount) {
                    Text("Apple-Account").tag(true)
                    Text("Zertifikat").tag(false)
                }
                .pickerStyle(.segmented)
            }
            if useAccount && account.isReady {
                LabeledContent("Team", value: account.team.map { "\($0.displayName) (\($0.id))" } ?? "–")
                Toggle("Mehr Arbeitsspeicher (+RAM)", isOn: $options.increasedMemoryLimit)
                Toggle("Erweiterungen mit eigener App-ID", isOn: $options.registerExtensions)
            } else if identities.isEmpty {
                Label("Kein Zertifikat vorhanden. Im Tab „Signer“ mit der Apple-ID anmelden oder ein .p12 mit Profil importieren.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else {
                Picker("Zertifikat", selection: Binding(get: { identity?.id }, set: { identityID = $0 })) {
                    ForEach(identities) { identity in
                        Text(identity.name).tag(Optional(identity.id))
                    }
                }
                if let identity {
                    let bundleID = options.bundleID.trimmed.isEmpty ? app.bundleID : options.bundleID.trimmed
                    if let profile = IdentityStore.bestProfile(for: identity, bundleID: bundleID, udid: device.udid, in: profiles) {
                        LabeledContent("Profil", value: profile.name)
                        LabeledContent("Gültig bis", value: min(profile.expirationDate, identity.expirationDate).formatted(date: .abbreviated, time: .omitted))
                    } else {
                        Label("Kein gültiges Profil für „\(bundleID)“ und dieses iPhone. Profil importieren oder Bundle-ID anpassen.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    if identity.isExpired {
                        Label("Das Zertifikat ist abgelaufen.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
        } header: {
            Text("Signieren mit")
        } footer: {
            if useAccount && account.isReady {
                Text("Beim Apple-Account hängt Quill die Team-ID an die Bundle-ID an, damit sie zu deinem Account gehört.")
            }
        }
    }

    private var identitySection: some View {
        Section {
            LabeledContent("Name") {
                TextField(app.name, text: $options.displayName).multilineTextAlignment(.trailing)
            }
            LabeledContent("Bundle-ID") {
                TextField(app.bundleID, text: $options.bundleID)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            LabeledContent("Version") {
                TextField(app.version, text: $options.version).multilineTextAlignment(.trailing)
            }
            PhotosPicker(selection: $iconItem, matching: .images) {
                HStack {
                    Label("App-Icon ersetzen", systemImage: "photo")
                    Spacer()
                    if let iconData, let image = UIImage(data: iconData) {
                        Image(uiImage: image)
                            .resizable()
                            .frame(width: 32, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }
            }
        } header: {
            Text("App")
        } footer: {
            Text("Leere Felder behalten den Originalwert. Mit Zertifikat muss die Bundle-ID zur App-ID des Profils passen, sofern dieses kein Wildcard-Profil ist.")
        }
    }

    private var modificationSection: some View {
        Section("Anpassungen") {
            Toggle("App-Erweiterungen entfernen", isOn: $options.removePlugIns)
            Toggle("Watch-App entfernen", isOn: $options.removeWatchApp)
            Toggle("Gerätebeschränkung entfernen", isOn: $options.removeSupportedDevices)
            Toggle("URL-Schemata entfernen", isOn: $options.removeURLSchemes)
            Toggle("Dateifreigabe aktivieren", isOn: $options.enableFileSharing)
            LabeledContent("Mindest-iOS") {
                TextField("unverändert", text: $options.minimumOSVersion)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.decimalPad)
            }
        }
    }

    private var librarySection: some View {
        Section {
            ForEach(libraries, id: \.self) { url in
                Label(url.lastPathComponent, systemImage: "shippingbox")
            }
            .onDelete { libraries.remove(atOffsets: $0) }
            Button("Bibliothek hinzufügen", systemImage: "plus") { picker = .libraries }
        } header: {
            Text("Zusätzliche Bibliotheken")
        } footer: {
            Text(".dylib-Dateien oder .framework-Ordner werden nach Frameworks/ kopiert, mitsigniert und beim Start geladen.")
        }
    }

    private var advancedSection: some View {
        Section("Erweitert") {
            Button {
                picker = .entitlements
            } label: {
                LabeledContent("Eigene Entitlements", value: entitlementsURL?.lastPathComponent ?? "aus Profil")
            }
            if entitlementsURL != nil {
                Button("Eigene Entitlements entfernen", role: .destructive) { entitlementsURL = nil }
            }
            if !(useAccount && account.isReady) {
                Toggle("embedded.mobileprovision weglassen", isOn: $options.excludeProvisioningProfile)
            }
            Toggle("Nach dem Signieren installieren", isOn: $options.installAfterSigning)
            Button("Anpassungen als Standard sichern") { options.saveAsDefaults() }
        }
    }

    // MARK: - Ablauf

    private func startSigning() {
        guard let method else { return }
        errorText = nil
        var input = SigningInput(source: app, options: options, method: method)
        input.libraries = libraries
        input.iconData = iconData
        input.entitlementsURL = entitlementsURL
        input.install = options.installAfterSigning

        Task {
            let scopedEntitlements = entitlementsURL?.startAccessingSecurityScopedResource() ?? false
            defer { if scopedEntitlements { entitlementsURL?.stopAccessingSecurityScopedResource() } }
            do {
                let outcome = try await pipeline.run(input, context: context)
                signedApp = outcome.signed
                installedApp = outcome.installed
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}
