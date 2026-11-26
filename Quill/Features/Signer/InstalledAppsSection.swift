import SwiftData
import SwiftUI

/// Von Quill installierte Apps mit Restlaufzeit, Erneuern und Entfernen.
struct InstalledAppsSection: View {
    let apps: [InstalledApp]

    @Environment(\.modelContext) private var context
    @Environment(DeviceLink.self) private var device
    @Environment(SigningPipeline.self) private var pipeline
    @Environment(RefreshService.self) private var refresher

    @State private var removing: InstalledApp?
    @State private var confirmRemove = false
    @State private var errorText: String?

    var body: some View {
        Section {
            if apps.isEmpty {
                Text("Noch keine App installiert.")
                    .foregroundStyle(.secondary)
            }
            ForEach(apps) { app in
                InstalledAppRow(app: app, isRefreshing: refresher.refreshing.contains(app.id)) {
                    refresh(app)
                }
                .swipeActions(edge: .trailing) {
                    Button("Entfernen", systemImage: "trash", role: .destructive) {
                        removing = app
                        confirmRemove = true
                    }
                    .tint(.red)
                }
                .swipeActions(edge: .leading) {
                    Button("Erneuern", systemImage: "arrow.clockwise") { refresh(app) }
                        .tint(.blue)
                }
            }
            if !apps.isEmpty {
                Button {
                    Task { await refresher.refreshAll(apps, pipeline: pipeline, context: context) }
                } label: {
                    Label("Alle erneuern", systemImage: "arrow.clockwise")
                }
                .disabled(refresher.isRefreshingAll || pipeline.isRunning)
            }
            NavigationLink {
                AutomationGuideView()
            } label: {
                Label("Automatisch erneuern", systemImage: "clock.arrow.2.circlepath")
            }
            if let error = refresher.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Installierte Apps")
        } footer: {
            if !apps.isEmpty {
                Text("Beim Erneuern bleiben die Daten der App erhalten. Quill erinnert einen Tag vor Ablauf.")
            }
        }
        .confirmationDialog("App entfernen?", isPresented: $confirmRemove, titleVisibility: .visible, presenting: removing) { app in
            Button("Vom iPhone löschen", role: .destructive) { uninstall(app) }
            Button("Nur aus der Liste entfernen") { forget(app) }
        } message: { app in
            Text("Beim Löschen vom iPhone gehen die Daten von „\(app.name)“ verloren.")
        }
        .messageAlert(message: $errorText)
    }

    private func refresh(_ app: InstalledApp) {
        Task { await refresher.refresh(app, pipeline: pipeline, context: context) }
    }

    private func uninstall(_ app: InstalledApp) {
        Task {
            do {
                try await device.uninstall(bundleID: app.bundleID)
                forget(app)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func forget(_ app: InstalledApp) {
        RefreshService.cancelReminder(for: app)
        context.delete(app)
        try? context.save()
        WidgetPublisher.publish()
    }
}

struct InstalledAppRow: View {
    let app: InstalledApp
    let isRefreshing: Bool
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let icon = app.iconURL {
                AppIconView(url: icon, size: 40)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .lineLimit(1)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(detailStyle)
            }
            Spacer(minLength: 8)
            if isRefreshing {
                ProgressView()
            } else {
                Button("Erneuern", systemImage: "arrow.clockwise", action: refresh)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
        }
    }

    private var detail: String {
        let version = "Version \(app.version)"
        if app.isExpired { return "\(version) · abgelaufen" }
        return "\(version) · noch \(app.daysLeft) Tag\(app.daysLeft == 1 ? "" : "e")"
    }

    /// Farbe nur als Warnung: ab zwei Tagen Restlaufzeit orange, abgelaufen rot.
    private var detailStyle: Color {
        if app.isExpired { return .red }
        return app.expirationDate.timeIntervalSinceNow > 2 * 86_400 ? .secondary : .orange
    }
}
