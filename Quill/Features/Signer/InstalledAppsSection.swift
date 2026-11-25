import SwiftData
import SwiftUI

/// Liste der von Quill installierten Apps mit Restlaufzeit, Refresh und Entfernen.
struct InstalledAppsSection: View {
    let apps: [InstalledApp]

    @Environment(\.modelContext) private var context
    @Environment(DeviceLink.self) private var device
    @Environment(SigningPipeline.self) private var pipeline
    @Environment(RefreshService.self) private var refresher

    @State private var removing: InstalledApp?
    @State private var errorText: String?

    var body: some View {
        Section {
            if apps.isEmpty {
                Text("Noch keine App über Quill installiert.")
                    .foregroundStyle(.secondary)
            }
            ForEach(apps) { app in
                InstalledAppRow(app: app,
                                isRefreshing: refresher.refreshing.contains(app.id),
                                refresh: { refresh(app) },
                                remove: { removing = app })
            }
            if let error = refresher.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            HStack {
                Text("Installierte Apps (\(apps.count)) · 7-Tage-Refresh (Daten bleiben)")
                Spacer()
                Button {
                    Task { await refresher.refreshAll(apps, pipeline: pipeline, context: context) }
                } label: {
                    Label("Refresh All", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.small)
                .disabled(apps.isEmpty || refresher.isRefreshingAll || pipeline.isRunning)
            }
        } footer: {
            if apps.contains(where: { $0.method == .account }) {
                Text("Kostenlose Accounts: höchstens drei Apps gleichzeitig. Quill erinnert 24 Stunden vor Ablauf.")
            }
        }
        .confirmationDialog("„\(removing?.name ?? "")“ entfernen?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Vom iPhone löschen", role: .destructive) {
                if let app = removing { uninstall(app) }
            }
            Button("Nur aus der Liste entfernen") {
                if let app = removing { forget(app) }
            }
        } message: {
            Text("Beim Löschen vom iPhone gehen die Daten der App verloren.")
        }
        .alert("Fehler", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
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
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let icon = app.iconURL {
                AppIconView(url: icon, size: 40)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("\(app.name) (v\(app.version))").font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 10, height: 10)
                    Text(app.isExpired ? "abgelaufen" : "\(app.daysLeft)d übrig")
                    Text("•")
                    Text(abbreviated(app.bundleID)).lineLimit(1)
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(statusColor)
            }
            Spacer(minLength: 8)
            if isRefreshing {
                ProgressView()
            } else {
                Button(action: refresh) {
                    Label("Refresh", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.small)
            }
            Button(action: remove) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .controlSize(.small)
            .accessibilityLabel("Entfernen")
        }
        .padding(.vertical, 2)
    }

    /// Grün über 2 Tage, gelb darunter, rot abgelaufen.
    private var statusColor: Color {
        if app.isExpired { return .red }
        return app.expirationDate.timeIntervalSinceNow > 2 * 86_400 ? .green : .yellow
    }

    private func abbreviated(_ bundleID: String) -> String {
        guard bundleID.count > 22 else { return bundleID }
        return "\(bundleID.prefix(3))…\(bundleID.suffix(16))"
    }
}
