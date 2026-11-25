import SwiftData
import SwiftUI

/// Drei Schritte: LiveContainer laden, signiert installieren, Zertifikat übergeben.
struct LiveContainerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.modelContext) private var context
    @Environment(LiveContainerService.self) private var service
    @Environment(SigningPipeline.self) private var pipeline
    @Environment(AppleAccountService.self) private var account

    @Query(filter: #Predicate<InstalledApp> { $0.isLiveContainer }) private var installed: [InstalledApp]

    @State private var increasedMemory = true
    @State private var password = String(randomPassword().prefix(10))
    @State private var certificateURL: URL?
    @State private var errorText: String?
    @State private var working = false

    private var current: InstalledApp? { installed.first }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("LiveContainer startet Apps in einer Art Container. So zählt nur LiveContainer selbst zu den drei Apps eines kostenlosen Accounts.")
                        .font(.callout)
                    LabeledContent("Installiert", value: current.map { "v\($0.version), noch \($0.daysLeft) Tage" } ?? "nein")
                    LabeledContent("Aktuell") {
                        if let latest = service.latest {
                            Text("v\(latest.version)")
                        } else if service.isLoading {
                            ProgressView()
                        } else {
                            Button("Prüfen") { Task { await loadLatest() } }
                        }
                    }
                }

                Section {
                    Toggle("Mehr Arbeitsspeicher anfragen", isOn: $increasedMemory)
                        .disabled(!account.isReady)
                    if let progress = service.downloadProgress {
                        ProgressView("Lade LiveContainer …", value: progress)
                    } else if pipeline.isRunning {
                        PipelineProgressView()
                    }
                    Button {
                        Task { await install() }
                    } label: {
                        Label(current == nil ? "Laden und installieren" : "Aktualisieren",
                              systemImage: "arrow.down.app")
                            .frame(maxWidth: .infinity)
                    }
                    .primaryActionRow()
                    .disabled(working || pipeline.isRunning)
                } header: {
                    Text("1. Laden und installieren")
                } footer: {
                    Text("Quelle: offizielles Release auf github.com/LiveContainer/LiveContainer. Erweiterungen bleiben erhalten, weil Multitasking sie braucht; mit einem kostenlosen Account kostet das zusätzliche App-IDs.")
                }

                Section {
                    LabeledContent("Passwort") {
                        TextField("Passwort", text: $password)
                            .multilineTextAlignment(.trailing)
                            .font(.body.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    if let certificateURL {
                        ShareLink(item: certificateURL) {
                            Label("Zertifikat in Dateien sichern", systemImage: "square.and.arrow.up")
                        }
                        Button("Passwort kopieren", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = password
                        }
                    } else {
                        Button("Zertifikat für LiveContainer erzeugen", systemImage: "key") {
                            Task { await makeCertificate() }
                        }
                        .disabled(current == nil || password.isEmpty || working)
                    }
                } header: {
                    Text("2. Zertifikat übergeben")
                } footer: {
                    Text("Ohne JIT signiert LiveContainer jede App selbst, und zwar mit demselben Zertifikat, mit dem LiveContainer signiert wurde. Wer Datei und Passwort hat, kann damit signieren.")
                }

                Section {
                    Text("In LiveContainer: Einstellungen → „Import Certificate“ → die gesicherte Datei wählen → Passwort einfügen. Danach unter „JIT-Less Mode Diagnose“ den Test starten.")
                        .font(.callout)
                    Button("LiveContainer öffnen", systemImage: "arrow.up.forward.app") {
                        UIPasteboard.general.string = password
                        openURL(LiveContainerService.appURL)
                    }
                    .disabled(current == nil)
                } header: {
                    Text("3. In LiveContainer importieren")
                }

                if let errorText {
                    Section { Label(errorText, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
            }
            .navigationTitle("LiveContainer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                        .disabled(pipeline.isRunning)
                }
            }
            .task { if service.latest == nil { await loadLatest() } }
            .onChange(of: password) { certificateURL = nil }
        }
    }

    private func loadLatest() async {
        do {
            _ = try await service.fetchLatest()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func install() async {
        working = true
        defer { working = false }
        errorText = nil
        do {
            let release: LiveContainerService.Release
            if let latest = service.latest {
                release = latest
            } else {
                release = try await service.fetchLatest()
            }
            guard let method = pipeline.defaultMethod(context: context) else {
                throw AppError("Kein Zertifikat vorhanden. Mit der Apple-ID anmelden oder ein .p12 mit Profil importieren.")
            }
            let source = try await service.download(release, context: context)
            var options = SignOptions.loadDefaults()
            options.removePlugIns = false
            options.registerExtensions = true
            options.increasedMemoryLimit = increasedMemory && account.isReady
            options.displayName = ""
            options.bundleID = ""
            options.version = ""
            try await pipeline.run(SigningInput(source: source, options: options, method: method), context: context)
            certificateURL = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func makeCertificate() async {
        guard let current else { return }
        working = true
        defer { working = false }
        errorText = nil
        do {
            certificateURL = try await service.certificateForLiveContainer(installed: current, password: password,
                                                                         account: account, context: context)
        } catch {
            errorText = error.localizedDescription
        }
    }
}
