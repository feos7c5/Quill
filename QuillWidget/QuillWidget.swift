import AppIntents
import SwiftUI
import WidgetKit

@main
struct QuillWidgetBundle: WidgetBundle {
    var body: some Widget {
        StatusWidget()
        RefreshControl()
    }
}

// MARK: - Daten

struct StatusEntry: TimelineEntry {
    let date: Date
    /// nil: keine App Group, das Widget kann nichts lesen.
    let snapshot: WidgetSnapshot?
}

struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: .now, snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(StatusEntry(date: .now, snapshot: context.isPreview ? .preview : current()))
    }

    /// Ein Eintrag jetzt und je einer um Mitternacht der nächsten Tage, damit die Resttage stimmen,
    /// ohne dass die App schreiben muss. Die App lädt die Zeitleiste bei Änderungen neu.
    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        let snapshot = current()
        let calendar = Calendar.current
        var entries = [StatusEntry(date: .now, snapshot: snapshot)]
        for day in 1...7 {
            if let date = calendar.date(byAdding: .day, value: day, to: calendar.startOfDay(for: .now)) {
                entries.append(StatusEntry(date: date, snapshot: snapshot))
            }
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    private func current() -> WidgetSnapshot? {
        guard WidgetSnapshot.directory != nil else { return nil }
        return WidgetSnapshot.load() ?? .empty
    }
}

extension WidgetSnapshot {
    static let preview = WidgetSnapshot(
        apps: [
            .init(name: "LiveContainer", bundleID: "com.kdt.livecontainer.ABCDE12345", expiration: .now.addingTimeInterval(6 * 86_400)),
            .init(name: "Working Copy", bundleID: "com.example.workingcopy", expiration: .now.addingTimeInterval(2 * 86_400)),
        ],
        updatedAt: .now, deviceReady: true, signerReady: true
    )
}

// MARK: - Widget

struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "QuillStatus", provider: StatusProvider()) { entry in
            StatusWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Quill")
        .description("Restlaufzeit der Apps und Refresh mit einem Tipp.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct StatusWidgetView: View {
    let entry: StatusEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let snapshot = entry.snapshot {
            switch family {
            case .accessoryCircular: circular(snapshot)
            case .accessoryRectangular: rectangular(snapshot)
            case .accessoryInline: inline(snapshot)
            case .systemMedium: medium(snapshot)
            default: small(snapshot)
            }
        } else {
            Text("Widget braucht die App Group. Siehe README.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Home-Bildschirm

    private func small(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            header(snapshot)
            Spacer(minLength: 0)
            if let next = snapshot.nextApp {
                Text("\(next.daysLeft(at: entry.date))")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(color(next))
                    .contentTransition(.numericText())
                Text("Tage · \(next.name)")
                    .font(.caption)
                    .lineLimit(1)
            } else {
                Text("Keine Apps").font(.headline)
            }
        }
        .widgetURL(WidgetSnapshot.refreshAllURL)
    }

    private func medium(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                header(snapshot)
                Spacer()
                Link(destination: WidgetSnapshot.refreshAllURL) {
                    Label("Refresh All", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.green.opacity(0.25)))
                }
            }
            if snapshot.apps.isEmpty {
                Text("Noch keine App über Quill installiert.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(snapshot.apps.sorted { $0.expiration < $1.expiration }.prefix(3)) { app in
                Link(destination: WidgetSnapshot.refreshURL(for: app.bundleID)) {
                    HStack(spacing: 8) {
                        icon(app)
                        Text(app.name).font(.callout).lineLimit(1)
                        Spacer()
                        Circle().fill(color(app)).frame(width: 8, height: 8)
                        Text(app.expiration < entry.date ? "abgelaufen" : "\(app.daysLeft(at: entry.date))d")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(color(app))
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func header(_ snapshot: WidgetSnapshot) -> some View {
        HStack(spacing: 4) {
            Image(systemName: snapshot.deviceReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(snapshot.deviceReady ? .green : .orange)
            Text("Quill").font(.caption.weight(.semibold))
        }
    }

    @ViewBuilder
    private func icon(_ app: WidgetSnapshot.App) -> some View {
        if let url = WidgetSnapshot.iconURL(for: app.bundleID), let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().frame(width: 22, height: 22).clipShape(RoundedRectangle(cornerRadius: 5))
        } else {
            RoundedRectangle(cornerRadius: 5).fill(.quaternary).frame(width: 22, height: 22)
        }
    }

    // MARK: Sperrbildschirm

    private func circular(_ snapshot: WidgetSnapshot) -> some View {
        Gauge(value: Double(min(7, snapshot.nextApp?.daysLeft(at: entry.date) ?? 0)), in: 0...7) {
            Image(systemName: "signature")
        } currentValueLabel: {
            Text("\(snapshot.nextApp?.daysLeft(at: entry.date) ?? 0)")
        }
        .gaugeStyle(.accessoryCircular)
        .widgetURL(WidgetSnapshot.refreshAllURL)
    }

    private func rectangular(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Quill").font(.headline).widgetAccentable()
            ForEach(snapshot.apps.sorted { $0.expiration < $1.expiration }.prefix(2)) { app in
                Text("\(app.name): \(app.daysLeft(at: entry.date)) T.").font(.caption).lineLimit(1)
            }
            if snapshot.apps.isEmpty { Text("Keine Apps").font(.caption) }
        }
        .widgetURL(WidgetSnapshot.refreshAllURL)
    }

    @ViewBuilder
    private func inline(_ snapshot: WidgetSnapshot) -> some View {
        if let next = snapshot.nextApp {
            Text("\(next.name): \(next.daysLeft(at: entry.date)) Tage")
        } else {
            Text("Quill: keine Apps")
        }
    }

    private func color(_ app: WidgetSnapshot.App) -> Color {
        if app.expiration < entry.date { return .red }
        return app.expiration.timeIntervalSince(entry.date) > 2 * 86_400 ? .green : .yellow
    }
}

// MARK: - Steuerzentrale

/// Öffnet Quill und startet „Refresh All“. Aus dem Widget heraus öffnet es nur die App;
/// die Arbeit läuft dort, weil nur die App Zugriff auf Zertifikate und Kopplung hat.
struct OpenRefreshIntent: AppIntent {
    static let title: LocalizedStringResource = "Quill Refresh"
    static let description = IntentDescription("Öffnet Quill und erneuert alle Apps.")

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(WidgetSnapshot.refreshAllURL))
    }
}

struct RefreshControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "QuillRefreshControl") {
            ControlWidgetButton(action: OpenRefreshIntent()) {
                Label("Quill Refresh", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .displayName("Quill Refresh")
        .description("Öffnet Quill und erneuert alle Apps.")
    }
}
