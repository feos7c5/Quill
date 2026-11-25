import BackgroundTasks
import Foundation
import Observation
import SwiftData
import UserNotifications

/// Erneuert installierte Apps, bevor ihr Profil abläuft (kostenlose Accounts: 7 Tage).
@MainActor
@Observable
final class RefreshService {
    private(set) var refreshing: Set<UUID> = []
    private(set) var isRefreshingAll = false
    private(set) var lastError: String?

    static var taskIdentifier: String { (Bundle.main.bundleIdentifier ?? "quill") + ".refresh" }
    /// Ab so vielen Tagen Restlaufzeit gilt eine App als „bald ablaufend“.
    static let dueWithinDays = 3

    func refresh(_ app: InstalledApp, pipeline: SigningPipeline, context: ModelContext, interactive: Bool = true) async {
        guard !refreshing.contains(app.id) else { return }
        refreshing.insert(app.id)
        defer { refreshing.remove(app.id) }
        lastError = nil
        do {
            try await pipeline.refresh(app, context: context, interactive: interactive)
        } catch {
            lastError = "\(app.name): \(error.localizedDescription)"
        }
        WidgetPublisher.publish()
    }

    /// Erneuert alle Apps nacheinander, Quill zuerst, dann die am frühesten ablaufende.
    /// Bricht bei einem Anmelde- oder Verbindungsfehler einmal ab statt bei jeder App.
    /// Liefert die Fehlermeldungen; leer bedeutet: alles erneuert.
    @discardableResult
    func refreshAll(_ apps: [InstalledApp], pipeline: SigningPipeline, context: ModelContext,
                    interactive: Bool = true) async -> [String] {
        guard !isRefreshingAll else { return ["Ein Refresh läuft bereits."] }
        isRefreshingAll = true
        defer { isRefreshingAll = false }
        lastError = nil
        var failures: [String] = []
        for app in apps.sorted(by: refreshOrder) {
            refreshing.insert(app.id)
            defer { refreshing.remove(app.id) }
            do {
                try await pipeline.refresh(app, context: context, interactive: interactive)
            } catch {
                failures.append("\(app.name): \(error.localizedDescription)")
                if Self.isBlocking(error) { break }
            }
        }
        if !failures.isEmpty { lastError = failures.joined(separator: "\n") }
        WidgetPublisher.publish()
        return failures
    }

    /// Fehler, bei denen weitere Apps ebenfalls scheitern würden.
    private static func isBlocking(_ error: Error) -> Bool {
        let text = error.localizedDescription
        return ["anmelden", "Bestätigungscode", "LocalDevVPN", "koppeln", "gekoppelt"].contains { text.contains($0) }
    }

    /// Quill selbst zuerst, danach nach Ablaufdatum.
    private func refreshOrder(_ a: InstalledApp, _ b: InstalledApp) -> Bool {
        let own = Bundle.main.bundleIdentifier ?? ""
        let aOwn = a.originalBundleID == own, bOwn = b.originalBundleID == own
        if aOwn != bOwn { return aOwn }
        return a.expirationDate < b.expirationDate
    }

    // MARK: - Erinnerung

    /// Mitteilung 24 Stunden vor Ablauf.
    static func scheduleReminder(for app: InstalledApp) {
        let center = UNUserNotificationCenter.current()
        let identifier = "refresh-\(app.bundleID)"
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        let fireDate = app.expirationDate.addingTimeInterval(-24 * 3600)
        guard fireDate > .now else { return }
        let content = UNMutableNotificationContent()
        content.title = "„\(app.name)“ läuft morgen ab"
        content.body = "In Quill auf „Refresh“ tippen, damit die App weiter startet. Die Daten bleiben erhalten."
        content.sound = .default
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }

    static func cancelReminder(for app: InstalledApp) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["refresh-\(app.bundleID)"])
    }

    // MARK: - Hintergrund

    /// Registriert die Hintergrundaufgabe. Muss vor dem Ende des App-Starts laufen.
    ///
    /// iOS entscheidet selbst, wann sie läuft. Erfolg ist nur möglich, wenn LocalDevVPN
    /// verbunden ist und (beim Apple-Account) ohne 2FA angemeldet werden kann. Verlässlicher
    /// ist eine tägliche Kurzbefehl-Automation mit „Apps erneuern“.
    static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            let work = Task { @MainActor in
                let summary = await AppServices.shared.refreshApps(onlyDue: true, interactive: false)
                scheduleBackgroundRefresh()
                task.setTaskCompleted(success: summary.failures.isEmpty)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func scheduleBackgroundRefresh() {
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = .now.addingTimeInterval(12 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }
}
