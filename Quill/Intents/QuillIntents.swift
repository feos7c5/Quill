import AppIntents
import SwiftData
import Foundation

// Aktionen für die Kurzbefehle-App. Für automatisches Erneuern eine persönliche
// Automation anlegen (täglich, „Sofort ausführen“):
//   1. „VPN festlegen“ → LocalDevVPN → Verbinden
//   2. „Warten“ 3 Sekunden
//   3. „Apps erneuern“ (Quill)
//   4. „VPN festlegen“ → Trennen (optional)

/// Erneuert Apps im Hintergrund, ohne Quill zu öffnen.
struct RefreshAppsIntent: AppIntent {
    static let title: LocalizedStringResource = "Apps erneuern"
    static let description = IntentDescription(
        "Signiert von Quill installierte Apps neu und installiert sie als Upgrade. Die Daten bleiben erhalten. Braucht eine Verbindung über LocalDevVPN.",
        categoryName: "Erneuern"
    )
    static let openAppWhenRun = false

    @Parameter(title: "Nur bald ablaufende", default: true)
    var onlyDue: Bool

    @Parameter(title: "Ablauf innerhalb (Tage)", default: 3, inclusiveRange: (1, 7))
    var days: Int

    static var parameterSummary: some ParameterSummary {
        When(\.$onlyDue, .equalTo, true) {
            Summary("Apps erneuern, die in \(\.$days) Tagen ablaufen") { \.$onlyDue }
        } otherwise: {
            Summary("Alle Apps erneuern") { \.$onlyDue }
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let summary = await AppServices.shared.refreshApps(onlyDue: onlyDue, withinDays: days, interactive: false)
        if !summary.failures.isEmpty && summary.refreshed == 0 && summary.total > 0 {
            throw RefreshFailed(message: summary.text)
        }
        return .result(value: summary.text, dialog: IntentDialog(stringLiteral: summary.text))
    }
}

/// Wie „Apps erneuern“, holt Quill aber nach vorn. Zuverlässiger bei großen Apps,
/// weil iOS Aktionen im Hintergrund nur begrenzt Zeit gibt.
struct OpenAndRefreshAppsIntent: AppIntent {
    static let title: LocalizedStringResource = "Quill öffnen und Apps erneuern"
    static let description = IntentDescription(
        "Öffnet Quill und erneuert alle bald ablaufenden Apps. Kann bei Bedarf nach einem Bestätigungscode fragen.",
        categoryName: "Erneuern"
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let summary = await AppServices.shared.refreshApps(onlyDue: true, interactive: true)
        return .result(value: summary.text)
    }
}

/// Restlaufzeit aller Apps und Verbindungsstatus als Text.
struct QuillStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Quill-Status"
    static let description = IntentDescription("Zeigt, wie lange die Apps noch laufen und ob Quill das iPhone erreicht.",
                                               categoryName: "Status")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = await AppServices.shared.statusText()
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

/// Tage bis zum nächsten Ablauf, als Zahl für Bedingungen („Wenn kleiner als 2 …“).
struct DaysUntilExpiryIntent: AppIntent {
    static let title: LocalizedStringResource = "Tage bis zum nächsten Ablauf"
    static let description = IntentDescription("Liefert die Restlaufzeit der App, die als nächste abläuft. Ohne Apps: 99.",
                                               categoryName: "Status")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let services = AppServices.shared
        let apps = (try? services.context.fetch(FetchDescriptor<InstalledApp>())) ?? []
        let days = apps.map(\.daysLeft).min() ?? 99
        return .result(value: days)
    }
}

struct RefreshFailed: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: message) }
}

struct QuillShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RefreshAppsIntent(),
            phrases: [
                "Apps mit \(.applicationName) erneuern",
                "\(.applicationName) erneuern",
            ],
            shortTitle: "Apps erneuern",
            systemImageName: "arrow.triangle.2.circlepath"
        )
        AppShortcut(
            intent: QuillStatusIntent(),
            phrases: [
                "\(.applicationName) Status",
                "Wie lange laufen meine Apps in \(.applicationName)",
            ],
            shortTitle: "Status",
            systemImageName: "clock.badge.checkmark"
        )
    }
}
