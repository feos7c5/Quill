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
