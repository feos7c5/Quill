import UserNotifications
import SwiftData
import SwiftUI

@main
struct QuillApp: App {
    private let services = AppServices.shared

    init() {
        RefreshService.registerBackgroundTask()
        // Mitteilungen (z. B. der Kopplungscode) auch zeigen, während Quill offen ist.
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // Schaltflächen in Listen in Textfarbe statt Blau, wie in Apples eigenen Apps
                // mit dezentem Erscheinungsbild; Schalter bleiben grün.
                .tint(.primary)
                .toggleStyle(QuillSwitchStyle())
                .environment(services.downloads)
                .environment(services.installer)
                .environment(services.transfer)
                .environment(services.clipboard)
                .environment(services.device)
                .environment(services.pairing)
                .environment(services.account)
                .environment(services.pipeline)
                .environment(services.refresher)
                .environment(services.liveContainer)
                .environment(services.udidProfile)
        }
        .modelContainer(services.container)
    }
}

enum AppTab: Hashable {
    case signer, library, files, sources, settings
}

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(DownloadManager.self) private var downloads
    @Environment(DeviceLink.self) private var device
    @AppStorage("downloads.autoImport") private var autoImport = true

    @State private var selection: AppTab = .signer
    @State private var errorMessage: String?
    @State private var identityImport: IdentifiedBatch?
    @State private var pendingPairing: Data?
    @State private var askPairing = false

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack { SignerView() }
                .tabItem { Label("Signieren", systemImage: "signature") }
                .tag(AppTab.signer)

            NavigationStack { LibraryView() }
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
                .tag(AppTab.library)

            NavigationStack {
                FileBrowserView(directory: Paths.documents, title: String(localized: "Dateien"))
            }
            .tabItem { Label("Dateien", systemImage: "folder") }
            .tag(AppTab.files)

            NavigationStack { SourcesView() }
                .tabItem { Label("Quellen", systemImage: "arrow.down.circle") }
                .tag(AppTab.sources)

            NavigationStack { SettingsView() }
                .tabItem { Label("Einstellungen", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .onOpenURL { url in handleIncoming(url) }
        .onAppear {
            downloads.onFinished = { url in
                guard autoImport, url.pathExtension.lowercased() == "ipa" else { return }
                importIPA(url)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                RefreshService.scheduleBackgroundRefresh()
                WidgetPublisher.publish()
            case .active:
                WidgetPublisher.publish()
            default:
                break
            }
        }
        .sheet(item: $identityImport) { batch in
            IdentityImportView(batch: batch)
        }
        .alert("Pairing-Datei übernehmen?", isPresented: $askPairing) {
            Button("Übernehmen") {
                if let data = pendingPairing { acceptPairing(data) }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Eine andere App möchte Quill eine Pairing-Datei geben. Sie gibt Quill denselben Zugriff auf dieses iPhone wie ein vertrauter Rechner und ersetzt eine vorhandene Kopplung. Nur annehmen, wenn du das gerade selbst ausgelöst hast.")
        }
        .alert("Fehler", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// Dateien über „Öffnen mit“/AirDrop und `quill://pairing?data=<Base64>`.
    private func handleIncoming(_ url: URL) {
        if url.scheme == "quill", url.host == "udid" {
            // Rückkehr aus den Einstellungen nach dem UDID-Profil; gespeichert hat der Dienst schon.
            selection = .signer
            if let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "value" })?.value {
                do { try device.setManualUDID(value) } catch { errorMessage = error.localizedDescription }
            }
            return
        }
        if url.scheme == "quill", url.host == "refresh-all" || url.host == "refresh" {
            selection = .signer
            startRefresh(bundleID: URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "bundle" })?.value)
            return
        }
        if url.scheme == "quill" {
            guard url.host == "pairing",
                  let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "data" })?.value,
                  let data = Data(base64Encoded: value.replacingOccurrences(of: " ", with: "+")) else {
                errorMessage = "Unbekannter Link."
                return
            }
            selection = .signer
            pendingPairing = data
            askPairing = true
            return
        }
        guard url.isFileURL else { return }
        switch url.pathExtension.lowercased() {
        case "ipa":
            selection = .library
            importIPA(url)
        case "p12", "pfx", "mobileprovision", "cer":
            do {
                selection = .signer
                identityImport = IdentifiedBatch(batch: try IdentityStore.collect([url]))
            } catch {
                errorMessage = error.localizedDescription
            }
        default:
            copyToDocuments(url)
        }
    }

    private func copyToDocuments(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let destination = Paths.uniqueURL(for: Paths.documents.appendingPathComponent(url.lastPathComponent))
            if url.standardizedFileURL.path != destination.standardizedFileURL.path,
               !url.standardizedFileURL.path.hasPrefix(Paths.documents.standardizedFileURL.path) {
                try FileManager.default.copyItem(at: url, to: destination)
            }
            selection = .files
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Vom Widget oder der Steuerzentrale: eine App oder alle erneuern.
    private func startRefresh(bundleID: String?) {
        let services = AppServices.shared
        Task {
            if let bundleID,
               let app = try? context.fetch(FetchDescriptor<InstalledApp>(predicate: #Predicate { $0.bundleID == bundleID })).first {
                await services.device.refresh()
                await services.refresher.refresh(app, pipeline: services.pipeline, context: context)
            } else {
                _ = await services.refreshApps(onlyDue: false, interactive: true)
            }
        }
    }

    private func acceptPairing(_ data: Data) {
        do {
            try device.importPairingFile(data)
            Task { await device.refresh() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importIPA(_ url: URL) {
        Task {
            do {
                _ = try await AppLibrary.importIPA(from: url, context: context)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}


final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}


/// Systemschalter mit grüner Farbe, unabhängig vom App-weiten Farbton.
struct QuillSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration)
            .toggleStyle(.switch)
            .tint(.green)
    }
}
