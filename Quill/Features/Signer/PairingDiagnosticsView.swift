import ActivityKit
import Network
import SwiftUI
import UserNotifications

/// Prüft mit einem Tipp alles, was Quill selbst für die Kopplung braucht, und schreibt einen Bericht.
/// Den Schritt in den Einstellungen kann keine App selbst ausführen; alles davor schon.
struct PairingDiagnosticsView: View {
    @Environment(PairingService.self) private var pairing
    @State private var checks: [Check] = []
    @State private var running = false

    struct Check: Identifiable {
        let id = UUID()
        let title: LocalizedStringKey
        let ok: Bool?
        let detail: String
    }

    var body: some View {
        List {
            Section {
                Button {
                    Task { await run() }
                } label: {
                    Label(running ? "Test läuft …" : "Selbsttest starten", systemImage: "stethoscope")
                }
                .disabled(running || pairing.isRunning)
            } footer: {
                Text("Quill spielt dabei selbst ein iPhone nach, das Quill in den Einstellungen auswählt. Der Code muss in Quill, als Mitteilung und in der Live-Aktivität erscheinen. Dauert etwa 20 Sekunden.")
            }
            if !checks.isEmpty {
                Section("Ergebnis") {
                    ForEach(checks) { check in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: symbol(check.ok))
                                .foregroundStyle(color(check.ok))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(check.title)
                                if !check.detail.isEmpty {
                                    Text(check.detail).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Section {
                    ShareLink(item: PairingLog.url) {
                        Label("Bericht teilen", systemImage: "square.and.arrow.up")
                    }
                    NavigationLink("Protokoll") { LogFileView(url: PairingLog.url, title: "Kopplung") }
                }
            }
        }
        .navigationTitle("Kopplung prüfen")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func symbol(_ ok: Bool?) -> String {
        switch ok {
        case true?: "checkmark.circle.fill"
        case false?: "xmark.circle.fill"
        case nil: "minus.circle"
        }
    }

    private func color(_ ok: Bool?) -> Color {
        switch ok {
        case true?: .green
        case false?: .red
        case nil: .secondary
        }
    }

    private func run() async {
        running = true
        checks = []
        defer { running = false }

        // Erst die Berechtigung erfragen, sonst ist der Status beim ersten Test „nicht festgelegt“.
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        let notifications = await UNUserNotificationCenter.current().notificationSettings()
        let notificationsOK = notifications.authorizationStatus == .authorized
        add("Mitteilungen erlaubt", notificationsOK,
            notificationsOK ? "" : String(localized: "Einstellungen → Apps → Quill → Mitteilungen einschalten."))

        let activities = ActivityAuthorizationInfo().areActivitiesEnabled
        add("Live-Aktivitäten erlaubt", activities,
            activities ? "" : String(localized: "Einstellungen → Apps → Quill → Live-Aktivitäten einschalten."))

        let wifi = await Self.wifiConnected()
        add("WLAN verbunden", wifi, wifi ? "" : String(localized: "Die Einstellungen finden Quill nur über WLAN."))

        pairing.startSelfTest()
        guard pairing.isRunning else {
            add("Kopplung gestartet", false, pairing.message)
            return
        }

        // Bonjour: Ist Quill so im Netzwerk sichtbar, wie die Einstellungen es suchen?
        let name = pairing.advertisedName ?? ""
        let outcome = await LocalNetworkProbe.check(type: "_remotepairing-pairable-host._tcp", name: name, seconds: 10)
        let visible = outcome == .visible
        add("Für die Einstellungen sichtbar (Bonjour)", visible,
            visible ? "" : String(localized: "Quill wurde im Netzwerk nicht gefunden. Lokales Netzwerk für Quill erlauben (Einstellungen → Apps → Quill)."))

        // Auf den Code und das Ende des Tests warten.
        var sawCode = false
        for _ in 0..<60 {
            if case .pin = pairing.phase { sawCode = true }
            if !pairing.isRunning { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        add("Code angezeigt", sawCode, "")
        let passed = pairing.selfTestPassed == true
        add("Code geprüft (wie in den Einstellungen)", passed, passed ? "" : pairing.message)
        if pairing.isRunning { pairing.cancel() }

        PairingLog.write("Self-test report: " + checks.map { $0.ok == true ? "OK" : "FAIL" }.joined(separator: ", "))
    }

    private func add(_ title: LocalizedStringKey, _ ok: Bool?, _ detail: String) {
        checks.append(Check(title: title, ok: ok, detail: detail))
    }

    private static func wifiConnected() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
            monitor.pathUpdateHandler = { path in
                monitor.cancel()
                continuation.resume(returning: path.status == .satisfied)
            }
            monitor.start(queue: .global())
        }
    }
}
