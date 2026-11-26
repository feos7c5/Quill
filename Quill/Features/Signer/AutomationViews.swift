import SwiftData
import SwiftUI

/// Anleitung für das automatische Erneuern über eine Kurzbefehl-Automation.
struct AutomationGuideView: View {
    @Environment(\.openURL) private var openURL
    @Query(sort: \InstalledApp.expirationDate) private var installed: [InstalledApp]

    var body: some View {
        List {
            Section {
                Text("iOS startet Quill nicht zuverlässig von selbst. Eine tägliche Automation in der Kurzbefehle-App erneuert die Apps dagegen zuverlässig, solange das iPhone im WLAN ist und LocalDevVPN verbinden kann.")
            }

            Section("Einrichten (einmal)") {
                StepRow(number: 1, text: "Kurzbefehle → Automation → „+“ → „Tageszeit“, z. B. 4:00 Uhr, täglich. „Sofort ausführen“ wählen und „Bei Ausführung benachrichtigen“ ausschalten.")
                StepRow(number: 2, text: "Aktion „VPN festlegen“ → LocalDevVPN → „Verbinden“.")
                StepRow(number: 3, text: "Aktion „Warten“ → 3 Sekunden.")
                StepRow(number: 4, text: "Aktion „Apps erneuern“ (Quill). „Nur bald ablaufende“ eingeschaltet lassen.")
                StepRow(number: 5, text: "Optional: „VPN festlegen“ → „Trennen“.")
                Button("Kurzbefehle öffnen", systemImage: "square.2.layers.3d") {
                    openURL(URL(string: "shortcuts://")!)
                }
            }

            Section {
                Label("Passwort zum Erneuern merken (Apple-ID-Anmeldung)", systemImage: "key")
                Label("Quill gekoppelt, LocalDevVPN installiert", systemImage: "link")
                Label("Die ursprüngliche IPA bleibt in der Bibliothek", systemImage: "square.grid.2x2")
            } header: {
                Text("Voraussetzungen")
            } footer: {
                Text("Fragt Apple beim Anmelden nach einem Bestätigungscode, bricht der Kurzbefehl ab und meldet das. Dann Quill einmal öffnen und anmelden; danach läuft es wieder ohne Code.")
            }

            Section {
                LabeledContent("Apps erneuern", value: "im Hintergrund")
                LabeledContent("Quill öffnen und Apps erneuern", value: "im Vordergrund")
                LabeledContent("Quill-Status", value: "Text")
                LabeledContent("Tage bis zum nächsten Ablauf", value: "Zahl")
            } header: {
                Text("Aktionen von Quill")
            } footer: {
                Text("Meldet die Automation „Zeitüberschreitung“, statt „Apps erneuern“ die Variante „Quill öffnen und Apps erneuern“ nehmen: iOS gibt Aktionen im Hintergrund nur begrenzt Zeit. Mit „Tage bis zum nächsten Ablauf“ und „Wenn“ lässt sich nur bei Bedarf erneuern.")
            }

            if let next = installed.first {
                Section("Jetzt") {
                    LabeledContent("Nächster Ablauf", value: "\(next.name), \(next.expirationDate.formatted(date: .abbreviated, time: .shortened))")
                }
            }
        }
        .navigationTitle("Automatisch erneuern")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// UDID ohne Kopplung: von Hand oder aus einem importierten Profil.
struct UDIDView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(DeviceLink.self) private var device
    @Environment(UDIDProfileService.self) private var profileService
    @Environment(AppleAccountService.self) private var account
    @Query private var profiles: [ProfileRecord]

    @State private var text = UserDefaults.standard.string(forKey: DeviceLink.manualUDIDKey) ?? ""
    @State private var errorText: String?

    /// UDIDs aus Profilen; bei genau einem Gerät ist es mit hoher Wahrscheinlichkeit dieses.
    private var candidates: [String] {
        Array(Set(profiles.flatMap(\.devices))).sorted()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Nie gesperrt: Schlägt die Profilinstallation fehl, meldet iOS das Quill nicht,
                    // deshalb muss ein neuer Versuch jederzeit möglich sein.
                    Button {
                        Task {
                            await profileService.prepareSigner(using: account)
                            profileService.start()
                        }
                    } label: {
                        if profileService.phase == .idle {
                            Label("Automatisch erkennen", systemImage: "sparkle.magnifyingglass")
                        } else {
                            Label("Erneut versuchen", systemImage: "arrow.clockwise")
                        }
                    }
                    if profileService.phase == .waiting {
                        // Das geladene Profil steht oben auf der Startseite der Einstellungen.
                        Button("Einstellungen öffnen", systemImage: "gear") { SystemSettings.open() }
                        Button("Abbrechen", systemImage: "xmark", role: .cancel) {
                            profileService.cancel()
                        }
                    }
                    switch profileService.phase {
                    case .idle:
                        EmptyView()
                    case .waiting:
                        Label("In Safari „Zulassen“ tippen, dann Einstellungen → „Profil geladen“ → Installieren. Danach öffnet Safari eine Seite, die zu Quill zurückführt.",
                              systemImage: "hourglass")
                            .font(.footnote)
                    case .received(let udid):
                        Label("Erkannt: \(udid)", systemImage: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    if let hint = profileService.hint {
                        Label(hint, systemImage: "info.circle")
                            .font(.footnote)
                    }
                    if profileService.phase != .idle {
                        ShareLink(item: LogBundle(), preview: SharePreview("Quill-logs.txt")) {
                            Label("Protokolle teilen", systemImage: "square.and.arrow.up")
                        }
                        NavigationLink("Protokoll") {
                            LogFileView(url: UDIDProfileService.logURL, title: "UDID-Erkennung")
                        }
                    }
                } footer: {
                    Text("Das Profil ist temporär: iOS gibt nur die UDID an Quill auf diesem iPhone weiter und installiert nichts dauerhaft. Nichts geht ins Internet.")
                }

                Section {
                    TextField("00008130-001C…", text: $text)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                } header: {
                    Text("UDID dieses iPhones")
                } footer: {
                    Text("Oder von Hand: Die UDID steht z. B. in der Bestätigung deines UDID-Registrierungsdienstes. Mit Kopplung erkennt Quill sie ohnehin automatisch.")
                }
                if !candidates.isEmpty {
                    Section("Aus importierten Profilen") {
                        ForEach(candidates, id: \.self) { udid in
                            Button(udid) { text = udid }
                                .font(.caption.monospaced())
                        }
                    }
                }
                if let errorText {
                    Section { Label(errorText, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
            }
            .navigationTitle("UDID")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: profileService.phase) { _, phase in
                if case .received(let udid) = phase { text = udid }
            }
            .onDisappear {
                if profileService.phase != .waiting { profileService.stop() }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") { save() }
                }
            }
        }
    }

    private func save() {
        do {
            try device.setManualUDID(text)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
