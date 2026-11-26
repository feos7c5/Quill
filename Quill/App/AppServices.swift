import SwiftData
import UIKit

/// Alle Dienste der App an einer Stelle. Die Oberfläche, Kurzbefehle (App Intents),
/// Widget-Links und die Hintergrundaufgabe greifen auf dieselben Objekte zu.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let container: ModelContainer
    let downloads = DownloadManager()
    let installer = InstallService()
    let transfer = WiFiTransferService()
    let clipboard = FileClipboard()
    let device = DeviceLink()
    let pairing = PairingService()
    let account = AppleAccountService()
    let refresher = RefreshService()
    let liveContainer = LiveContainerService()
    let pipeline: SigningPipeline

    private init() {
        Core.start()
        do {
            container = try ModelContainer(for: SigningIdentity.self, ProfileRecord.self, LibraryApp.self,
                                           InstalledApp.self, AppSource.self)
        } catch {
            fatalError("Datenbank konnte nicht geöffnet werden: \(error)")
        }
        pipeline = SigningPipeline(device: device, account: account, ota: installer)
    }

    var context: ModelContext { container.mainContext }

    struct RefreshSummary: Sendable {
        let total: Int
        let refreshed: Int
        let failures: [String]
        let nextExpiry: Date?

        var text: String {
            if total == 0 {
                if let nextExpiry {
                    return String(localized: "Nichts fällig. Nächster Ablauf: \(nextExpiry.formatted(date: .abbreviated, time: .shortened)).")
                }
                return String(localized: "Keine Apps zum Erneuern.")
            }
            var text = String(localized: "Erneuert: \(refreshed) von \(total)")
            if !failures.isEmpty { text += "\n" + failures.joined(separator: "\n") }
            return text
        }
    }

    /// Erneuert Apps für Kurzbefehle, Widget und Hintergrund.
    /// - Parameters:
    ///   - onlyDue: nur Apps, die innerhalb von `withinDays` Tagen ablaufen
    ///   - interactive: false = keine 2FA-Dialoge, bei Bedarf sofort abbrechen
    func refreshApps(onlyDue: Bool, withinDays: Int = RefreshService.dueWithinDays,
                     interactive: Bool) async -> RefreshSummary {
        // Zusätzliche Hintergrundzeit, falls der Kurzbefehl Quill nicht in den Vordergrund holt.
        let background = BackgroundTime(name: "Quill-Refresh")
        defer { background.end() }

        let all = (try? context.fetch(FetchDescriptor<InstalledApp>(sortBy: [SortDescriptor(\.expirationDate)]))) ?? []
        let limit = Date.now.addingTimeInterval(Double(withinDays) * 86_400)
        let due = onlyDue ? all.filter { $0.expirationDate < limit } : all
        guard !due.isEmpty else {
            WidgetPublisher.publish()
            return RefreshSummary(total: 0, refreshed: 0, failures: [], nextExpiry: all.first?.expirationDate)
        }

        let started = Date.now
        await device.refresh()
        let failures = await refresher.refreshAll(due, pipeline: pipeline, context: context, interactive: interactive)
        let refreshed = due.filter { $0.refreshedAt >= started }.count
        let remaining = (try? context.fetch(FetchDescriptor<InstalledApp>(sortBy: [SortDescriptor(\.expirationDate)]))) ?? []
        return RefreshSummary(total: due.count, refreshed: refreshed, failures: failures,
                              nextExpiry: remaining.first?.expirationDate)
    }

    /// Kurzer Status für Kurzbefehle.
    func statusText() async -> String {
        await device.refresh()
        let apps = (try? context.fetch(FetchDescriptor<InstalledApp>(sortBy: [SortDescriptor(\.expirationDate)]))) ?? []
        var lines = apps.map { app in
            app.isExpired ? String(localized: "\(app.name): abgelaufen") : "\(app.name): \(daysLeftText(app.daysLeft))"
        }
        if lines.isEmpty { lines.append(String(localized: "Keine Apps über Quill installiert.")) }
        switch device.state {
        case .ready: lines.append(String(localized: "Gekoppelt, LocalDevVPN verbunden."))
        case .unpaired: lines.append(String(localized: "Nicht gekoppelt."))
        case .unreachable: lines.append(String(localized: "Gekoppelt, aber nicht erreichbar (LocalDevVPN?)."))
        case .checking: break
        }
        WidgetPublisher.publish()
        return lines.joined(separator: "\n")
    }
}

/// Bittet iOS um zusätzliche Laufzeit im Hintergrund und gibt sie sicher wieder frei.
@MainActor
final class BackgroundTime {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
