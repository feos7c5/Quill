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
                    }
                    .disabled(working || pipeline.isRunning)
                } header: {
                    Text("1. Laden und installieren")
                } footer: {
                    Text("Quelle: offizielles Release auf github.com/LiveContainer/LiveContainer. Erweiterungen bleiben erhalten, weil Multitasking sie braucht; mit einem kostenlosen Account kostet das zusätzliche App-IDs.")
                }

                Section {
                    Button {
                        Task { await handOver() }
                    } label: {
                        Label("Zertifikat an LiveContainer übergeben", systemImage: "key")
                    }
                    .disabled(current == nil || working)
                    if let certificateURL {
                        ShareLink(item: certificateURL) {
                            Label("Zertifikat zusätzlich in Dateien sichern", systemImage: "square.and.arrow.up")
                        }
                        LabeledContent("Passwort") {
                            Text(password).font(.body.monospaced()).textSelection(.enabled)
                        }
                    }
                } header: {
                    Text("2. Zertifikat übergeben")
                } footer: {
                    Text("Quill öffnet LiveContainer und übergibt das Zertifikat, mit dem LiveContainer signiert wurde. LiveContainer braucht es, um Apps ohne JIT zu signieren. Danach in LiveContainer unter Einstellungen „JIT-Less Mode Diagnose“ den Test starten.")
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

    private func handOver() async {
        guard let current else { return }
        working = true
        defer { working = false }
        errorText = nil
        do {
            let url = try await service.certificateForLiveContainer(installed: current, password: password,
                                                                    account: account, context: context)
            certificateURL = url
            guard let link = LiveContainerService.importURL(certificate: try Data(contentsOf: url), password: password) else {
                throw AppError("Die Übergabe-Adresse für LiveContainer ließ sich nicht erzeugen.")
            }
            openURL(link) { accepted in
                if !accepted { errorText = String(localized: "LiveContainer ließ sich nicht öffnen. Ist es installiert?") }
            }
        } catch {
            errorText = error.localizedDescription
        }
    }
}
